// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {FeraHook} from "../../src/FeraHook.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {FeeLogic} from "../../src/libraries/FeeLogic.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @notice A minimal harness that runs TWO swaps against the SAME pool inside ONE
///         `PoolManager.unlock()` callback -- exactly the atomicity a real attacker gets from a
///         single (optionally flash-loan-funded) transaction, since Uniswap v4 flash accounting
///         lets one `unlock()` drive an unbounded number of `swap()` calls. Used to reproduce the
///         open-kritt flow-EWMA sign-flip finding: `_afterSwap` writes the state update from swap 1
///         BEFORE `_beforeSwap` prices swap 2, both inside the same top-level transaction.
contract AtomicMultiSwap is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager internal immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    struct Leg {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
    }

    function twoSwaps(Leg memory leg1, Leg memory leg2) external returns (BalanceDelta d1, BalanceDelta d2) {
        bytes memory result = manager.unlock(abi.encode(leg1, leg2));
        (d1, d2) = abi.decode(result, (BalanceDelta, BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (Leg memory leg1, Leg memory leg2) = abi.decode(data, (Leg, Leg));
        BalanceDelta d1 = _doSwap(leg1); // (1) priming swap -- afterSwap updates flowEwmaX
        BalanceDelta d2 = _doSwap(leg2); // (2) real toxic sell -- beforeSwap prices off THAT update
        return abi.encode(d1, d2);
    }

    function _doSwap(Leg memory leg) internal returns (BalanceDelta delta) {
        delta = manager.swap(
            leg.key,
            SwapParams({
                zeroForOne: leg.zeroForOne,
                amountSpecified: -int256(leg.amountIn),
                sqrtPriceLimitX96: leg.sqrtPriceLimitX96
            }),
            ""
        );
        int256 amount0 = int256(delta.amount0());
        int256 amount1 = int256(delta.amount1());
        if (amount0 < 0) leg.key.currency0.settle(manager, address(this), uint256(-amount0), false);
        if (amount1 < 0) leg.key.currency1.settle(manager, address(this), uint256(-amount1), false);
        if (amount0 > 0) leg.key.currency0.take(manager, address(this), uint256(amount0), false);
        if (amount1 > 0) leg.key.currency1.take(manager, address(this), uint256(amount1), false);
    }
}

/// @notice open-kritt finding: `_updateEwma`'s asymmetric flow ratchet (v3.5 fix, FeraConstants
///         MEME_FLOW_LAMBDA_ATTACK/_RELEASE NatSpec) is additive in the RAW, un-normalized tick
///         delta `r`. `newFlow = (lamF*flowX + (ONE-lamF)*(r<<16)) >> 16` IS a proper convex
///         combination of the OLD estimate and the new sample `r` -- but `r` itself is bounded only
///         by the pool's tick range, not by anything comparable to the estimator's own scale. A
///         single, sufficiently large swap's `r` can dominate even the slow (~0.98) RELEASE weight
///         and flip `flowEwmaX`'s SIGN in one update, regardless of how much genuine sell pressure
///         had accumulated. Since `_beforeSwap` prices a swap from the STORED state and `_afterSwap`
///         writes the update, and Uniswap v4 flash accounting lets one `unlock()` run many `swap()`
///         calls, an attacker chains (1) a cheap priming buy sized to flip the sign, then (2) the
///         real toxic sell, atomically -- dodging `_memeFee`'s one-sided sell surcharge
///         (MEME_SELL_ADDER_K_PIPS) entirely. Fixed in `_updateEwma` (FeraHook.sol) by clamping the
///         RELEASE-branch sample to `MEME_FLOW_RELEASE_R_CLAMP_TICKS` (FeraConstants.sol).
contract FlowEwmaSignFlip_PoCTest is Deployers {
    using StateLibrary for IPoolManager;

    FeraHook internal hook;
    PoolKey internal mkey;
    PoolId internal mid;

    int24 internal constant LO = -120_000;
    int24 internal constant HI = 120_000;

    // Sized empirically against this test's 5_000_000e18 full-range liquidity (see the probe this
    // PoC was calibrated from): a 150_000e18 sell moves the tick by ~500-600; a 5_000_000e18
    // priming buy against six such accumulated sells produces r ~ 15,000 ticks -- comfortably past
    // the pre-fix flip threshold (~12,000 ticks for that accumulated flow) and comfortably past the
    // fix's MEME_FLOW_RELEASE_R_CLAMP_TICKS = 2,000 clamp.
    uint256 internal constant SELL_LEG_SIZE = 150_000e18;
    uint256 internal constant PRIME_SIZE = 5_000_000e18;

    bytes32 internal constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int256,int256,uint24,uint256,bool,uint8)");

    function setUp() public {
        vm.warp(10_000_000);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0xF10E) << 14));
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(this)), hookAddr);
        hook = FeraHook(hookAddr);

        mkey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        mid = mkey.toId();
        hook.registerRegime(mkey, FeraTypes.Regime.MEME);
        manager.initialize(mkey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            mkey, ModifyLiquidityParams({tickLower: LO, tickUpper: HI, liquidityDelta: int256(5_000_000e18), salt: 0}), ""
        );
    }

    function _swap(bool zeroForOne, uint256 amtIn) internal returns (BalanceDelta) {
        return swap(mkey, zeroForOne, -int256(amtIn), "");
    }

    /// @dev Build genuine, substantially negative accumulated flow via SIX ordinary, one-sided
    ///      toxic sells (ATTACK branch throughout -- confirmed by the probe this PoC was calibrated
    ///      from: flowEwmaX strictly monotonically decreases across all six). This is exactly the
    ///      state the v3.5 release lambda is supposed to protect from being erased in one shot.
    function _buildNegativeFlow() internal returns (uint256 volBefore, int256 flowBefore) {
        for (uint256 i; i < 6; ++i) {
            _swap(true, SELL_LEG_SIZE); // zeroForOne == sell (default orientation)
        }
        (volBefore, flowBefore,,) = hook.memeStateOf(mid);
        assertLt(flowBefore, 0, "setup failed to build negative accumulated flow");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // (a) Pinpoints the exact bug: after genuinely accumulating negative flow over six real sells,
    //     ONE large priming buy (release branch) must NOT be able to flip flowEwmaX's sign in a
    //     single update. Pre-fix this FAILED (flipped to >= 0); post-fix (MEME_FLOW_RELEASE_R_CLAMP_TICKS) it PASSES.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_singlePrimingSwap_mustNotFlipFlowEwmaSign() public {
        (, int256 flowBefore) = _buildNegativeFlow();
        console2.log("flowEwmaX before priming (signed, Q16)");
        console2.logInt(flowBefore);

        _swap(false, PRIME_SIZE); // ONE priming buy -- the healing/release direction
        (, int256 flowAfter,,) = hook.memeStateOf(mid);
        console2.log("flowEwmaX after ONE priming buy (signed, Q16)");
        console2.logInt(flowAfter);

        assertLt(
            flowAfter,
            0,
            "BUG: a single priming buy flipped flowEwmaX's sign in one shot, erasing genuinely accumulated sell pressure"
        );
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // (b) The real exploit: chain the SAME priming buy + the actual toxic sell ATOMICALLY, inside
    //     ONE PoolManager.unlock() (mirrors a flash-loan-funded single transaction -- no other actor
    //     can intervene between the two legs). Confirms the toxic sell's dynamic fee still carries
    //     the one-sided sell surcharge (MEME_SELL_ADDER_K_PIPS) instead of being dodged.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_atomicPrimeThenDump_sellAdderMustNotBeDodged() public {
        (uint256 volBefore, int256 flowBefore) = _buildNegativeFlow();

        // The fee an honest, un-gamed estimator would charge THIS sell, computed directly off the
        // genuinely-accumulated pre-attack state -- the surcharge a fair mechanism owes here.
        uint24 honestSellFee = FeeLogic.quoteLpFee(
            FeeLogic.FeeInputs({
                regime: FeraTypes.Regime.MEME,
                isSell: true,
                volEwmaX: volBefore,
                flowEwmaX: flowBefore,
                marketOpen: false,
                poolPriceX96: 0,
                oraclePriceX96: 0
            })
        );
        uint24 feeBase = FeeLogic.quoteLpFee(
            FeeLogic.FeeInputs({
                regime: FeraTypes.Regime.MEME,
                isSell: false, // buy-side quote == feeBase, no adder ever applies to buys
                volEwmaX: volBefore,
                flowEwmaX: flowBefore,
                marketOpen: false,
                poolPriceX96: 0,
                oraclePriceX96: 0
            })
        );
        assertGt(honestSellFee, feeBase, "sanity: the pre-attack state should carry a real sell surcharge");

        AtomicMultiSwap atk = new AtomicMultiSwap(manager);
        // Fund the harness directly (it settles as its own payer -- CurrencySettler's plain-transfer
        // path) with enough of both currencies for the priming buy's cost and the sell's principal.
        currency0.transfer(address(atk), PRIME_SIZE + SELL_LEG_SIZE);
        currency1.transfer(address(atk), PRIME_SIZE + SELL_LEG_SIZE);

        vm.recordLogs();
        atk.twoSwaps(
            AtomicMultiSwap.Leg(mkey, false, PRIME_SIZE, MAX_PRICE_LIMIT), // (1) priming buy
            AtomicMultiSwap.Leg(mkey, true, SELL_LEG_SIZE, MIN_PRICE_LIMIT) // (2) the real toxic sell
        );
        uint24 dumpFee = _secondSwapFee(vm.getRecordedLogs());
        console2.log("honest (un-gamed) sell fee this state should carry", honestSellFee);
        console2.log("fee actually charged to the atomic toxic-sell leg ", dumpFee);

        assertGt(
            dumpFee,
            feeBase,
            "BUG: atomic prime-then-dump dodged the sell-adder entirely (fee collapsed to the bare buy-side base)"
        );
    }

    /// @dev Scans recorded logs for this pool's `Swap` events (IFeraHook) in emission order and
    ///      returns the `lpFeePips` of the SECOND one (the toxic-sell leg in the atomic sequence).
    function _secondSwapFee(Vm.Log[] memory logs) internal view returns (uint24 fee) {
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != SWAP_TOPIC) continue;
            if (logs[i].topics[1] != PoolId.unwrap(mid)) continue;
            ++seen;
            if (seen == 2) {
                (,, uint24 lpFeePips,,,) = abi.decode(logs[i].data, (int256, int256, uint24, uint256, bool, uint8));
                return lpFeePips;
            }
        }
        revert("expected two Swap events for this pool");
    }
}
