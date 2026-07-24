// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Vm} from "forge-std/Vm.sol";

import {FeraVault} from "../../src/FeraVault.sol";
import {FeraHook} from "../../src/FeraHook.sol";
import {FeraShare} from "../../src/shares/FeraShare.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {AnchorStaking} from "../../src/AnchorStaking.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {IFeraVault} from "../../src/interfaces/IFeraVault.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {MintableERC20} from "../utils/Mocks.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice LENS: unified fee-routing / self-swap drain (stage 2). See
///         `security/hardening/06-feerouting-audit.md` for the full write-up. VERDICT: CLOSED
///         (OPEN_DECISIONS.md#OD-17).
///
/// TWO facts are pinned here, both matter for the verdict:
///
///  (A) DOC CAVEAT, NOW GATED FOR REAL — the perf-fee self-swap's TWAP bound is only a SAME-BLOCK
///      guarantee. `contracts/VAULT_STRATEGY_V3.md` §9.3 states a pool creator "cannot fabricate a
///      favorable TWAP within the transaction that triggers the swap". True, but INCOMPLETE:
///      FeraHook's cumulative-tick oracle folds a manipulating swap's tick into `_lastTick` and lets
///      it drive the read via extrapolation the instant ONE block boundary is crossed —
///      `test_twapFullyLeaksToManipulatedTick` proves `consultTwapTick == spot` one block after a
///      push, on a pool whose observation ring hasn't matured. OD-17's own fix closes this directly
///      (not just via defense-in-depth): `VaultFees._routeUnifiedPerfFee` now requires
///      `oldestObservationAge(id) >= REBALANCE_TWAP_WINDOW_SEC` before even ATTEMPTING the
///      self-swap; below that, it skips straight to the fail-static in-kind fallback — the
///      shapeable reference is never trusted at all, not just bounded after the fact. Verified
///      empirically (a direct `oldestObservationAge` measurement in this exact scenario reads
///      `120s < 1800s`, confirming gate (A) — not dyn-fee — is what actually fires here) by
///      `testFuzz_shallowHistory_alwaysFallsStaticInKind` below: on a freshly-manipulated,
///      shallow-history pool, `swapped` is ALWAYS false and the full fee is ALWAYS preserved in-kind,
///      across a fuzzed sweep of push magnitudes and elapsed times under the window.
///
///  (B) DEFENSE-IN-DEPTH (reasoned, not independently test-constructed here) — even on a
///      MATURE-history pool where gate (A) would allow the swap attempt, a price manipulated right
///      at collection time is still expected to be caught: the same move that shifts spot also
///      spikes the MEME dynamic-fee overlay (`FeraHook._updateVol`, fast-attack ratchet) far above
///      `MAX_REBALANCE_SLIPPAGE_BPS` (1%), so the self-swap's output falls below `minOut` and
///      reverts — caught by the §9.2 try/catch and routed to the fail-static in-kind forward. An
///      attempt to construct this scenario directly (warm the oracle ring past the 1800s gate, then
///      manipulate at collection) did not reproduce cleanly in this harness — the ring's
///      `oldestObservationAge` did not advance past a single freeze interval the way the write path's
///      own comments describe, for reasons not fully traced. Left as reasoning-only pending further
///      investigation, rather than shipping a test whose own preconditions are unverified.
///
/// Net: gate (A) is the PRIMARY, verified defense — it never trusts a shapeable reference at all,
/// and is the mechanism actually observed firing in every "manipulated" scenario constructed here.
/// Dyn-fee (B) remains a plausible, reasoned-through backstop, not yet independently proven. The
/// only value ever at risk in either layer is the perf fee (protocol revenue), never depositor
/// principal/reserves; and the residual theoretical window (bleed the vol-EWMA back under 1% with
/// tiny swaps while HOLDING a dislocated price for many blocks against arbitrage) is impractical.
contract FeeRoutingTwapDrainPoC is Deployers {
    using StateLibrary for IPoolManager;

    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    AnchorStaking internal staking;
    FeraShare internal shareImpl;
    MintableERC20 internal stakeToken;

    address internal treasuryAddr = makeAddr("treasury");
    address internal opsAddr = makeAddr("ops");

    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant COOLDOWN = 3_600;
    uint256 internal constant JIT = 1_800;

    bytes32 internal constant SWAPPED_SIG = keccak256("PerfFeeSwapped(bytes32,uint8,address,uint256,address,uint256)");
    bytes32 internal constant FALLBACK_SIG = keccak256("PerfFeeInKindFallback(bytes32,uint8,address,uint256,bool)");

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();

        shareImpl = new FeraShare();
        stakeToken = new MintableERC20("STK", "STK");

        address predictedStaking = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rev = new RevenueDistributor(predictedStaking, treasuryAddr, opsAddr);
        staking = new AnchorStaking(IERC20(address(stakeToken)), IRevenueDistributor(address(rev)), address(this));
        require(address(staking) == predictedStaking, "staking addr mismatch");

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x5EE5) << 14));
        vault = new FeraVault(
            manager,
            IFeraHook(hookAddr),
            IRevenueDistributor(address(rev)),
            IAnchorStaking(address(staking)),
            address(shareImpl),
            address(this),
            address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);
    }

    // ── per-pool fixture: a well-behaved native/quote pool, quote allowlisted, native NOT ────────
    struct Pool {
        PoolKey key;
        PoolId id;
        address native;
        address quote;
        bool quoteIsToken0;
    }

    function _newPool(string memory tag) internal returns (Pool memory pl) {
        MintableERC20 a = new MintableERC20("A", "A"); // QUOTE
        MintableERC20 b = new MintableERC20("B", "B"); // NATIVE
        a.mint(address(this), 100_000_000e18);
        b.mint(address(this), 100_000_000e18);
        for (uint256 i; i < 2; ++i) {
            MintableERC20 t = i == 0 ? a : b;
            t.approve(address(vault), type(uint256).max);
            t.approve(address(swapRouter), type(uint256).max);
            t.approve(address(modifyLiquidityRouter), type(uint256).max);
        }
        bool quoteIsC0 = address(a) < address(b);
        Currency c0 = quoteIsC0 ? Currency.wrap(address(a)) : Currency.wrap(address(b));
        Currency c1 = quoteIsC0 ? Currency.wrap(address(b)) : Currency.wrap(address(a));
        pl.key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        pl.quote = address(a);
        pl.native = address(b);
        pl.quoteIsToken0 = quoteIsC0;
        vault.setAllowedQuoteAsset(pl.quote, true);
        pl.id = vault.createBaseLimitPool(pl.key, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, quoteIsC0, tag, tag);
        // quote is a reward token; native is NOT ⇒ forces the native→quote self-swap path.
        if (!staking.isRewardToken(pl.quote)) staking.addRewardToken(pl.quote);
    }

    function _seed(Pool memory pl) internal {
        vault.deposit(pl.id, 0, 1_000e18, 1_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT);
        _swap(pl, true, 1e15);
        _swap(pl, false, 1e15);
    }

    function _swap(Pool memory pl, bool zeroForOne, uint256 amt) internal {
        swapRouter.swap(
            pl.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// Generate a native-side (token = native) LP fee: input the native token.
    function _generateNativeFee(Pool memory pl, uint256 amt) internal {
        _swap(pl, !pl.quoteIsToken0, amt); // native input ⇒ zeroForOne == (native is token0) == !quoteIsToken0
    }

    /// Push spot toward `target` (native-cheap direction), against deep external liquidity so the
    /// pushed price is a stable level.
    function _pushToward(Pool memory pl, int24 target) internal {
        (uint160 sp0,,,) = manager.getSlot0(pl.id);
        uint128 extL = LiquidityAmounts.getLiquidityForAmounts(
            sp0, TickMath.getSqrtPriceAtTick(-24_000), TickMath.getSqrtPriceAtTick(24_000), 5_000_000e18, 5_000_000e18
        );
        modifyLiquidityRouter.modifyLiquidity(
            pl.key,
            ModifyLiquidityParams({tickLower: -24_000, tickUpper: 24_000, liquidityDelta: int256(uint256(extL)), salt: bytes32("ext")}),
            ""
        );
        _swapTo(pl, !pl.quoteIsToken0, 5_000_000e18, TickMath.getSqrtPriceAtTick(target));
    }

    function _swapTo(Pool memory pl, bool zeroForOne, uint256 amt, uint160 limit) internal {
        swapRouter.swap(
            pl.key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amt), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _decodeSwapEvent(Vm.Log[] memory logs) internal pure returns (bool found, uint256 nativeIn, uint256 quoteOut) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == SWAPPED_SIG) {
                (,, uint256 nIn,, uint256 qOut) = abi.decode(logs[i].data, (uint8, address, uint256, address, uint256));
                found = true;
                nativeIn = nIn;
                quoteOut = qOut;
            }
        }
    }

    function _hasEvent(Vm.Log[] memory logs, bytes32 sig) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) return true;
        }
        return false;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // (A) The "manipulation-resistant" TWAP the perf-fee self-swap is bounded against FULLY tracks
    //     the attacker's manipulated tick just ONE block after the push (shallow-history pool).
    // ═════════════════════════════════════════════════════════════════════════════════════════
    function test_twapFullyLeaksToManipulatedTick() public {
        Pool memory pl = _newPool("LEAK");
        _seed(pl);
        _generateNativeFee(pl, 2e18);

        // Before the push, with the ring collapsed to one recent point, the windowed read is not yet
        // ready (no anchor strictly older than now) — the bound would fall back to spot.
        (, bool readyBefore) = hook.consultTwapTick(pl.id, FeraConstants.REBALANCE_TWAP_WINDOW_SEC);
        assertFalse(readyBefore, "precondition: shallow history => windowed TWAP not yet ready (spot fallback)");

        int24 target = pl.quoteIsToken0 ? int24(300) : int24(-300);
        _pushToward(pl, target); // manipulate spot in this block ...
        vm.warp(block.timestamp + 120); // ... and let ONE block pass.

        (uint160 sp,,,) = manager.getSlot0(pl.id);
        int24 spotTick = TickMath.getTickAtSqrtPrice(sp);
        (int24 twapTick, bool ready) = hook.consultTwapTick(pl.id, FeraConstants.REBALANCE_TWAP_WINDOW_SEC);

        assertTrue(ready, "one block later the read is 'ready'");
        // The 30-MINUTE window's read == the CURRENT (manipulated) spot tick, to the tick: the
        // documented "cannot fabricate a favorable TWAP" holds ONLY within the same block.
        assertEq(twapTick, spotTick, "TWAP read fully equals the manipulated spot one block after the push");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // (A) A manipulated collection on a SHALLOW-history pool NEVER even attempts the perf-fee swap:
    //     `oldestObservationAge` (measured 120s in this exact scenario, see the contract header) is
    //     under the 1800s gate, so `_routeUnifiedPerfFee` skips straight to the fail-static in-kind
    //     fallback. collectFees never reverts. Value is fully preserved, not merely bounded.
    // ═════════════════════════════════════════════════════════════════════════════════════════
    function test_manipulatedCollection_failsStatic_valuePreserved() public {
        int24[3] memory mags = [int24(120), int24(300), int24(600)];
        uint256 preservedDemonstrations;
        for (uint256 k; k < mags.length; ++k) {
            Pool memory pl = _newPool("FS");
            _seed(pl);
            _generateNativeFee(pl, 2e18);
            // Manipulate spot in this block, then let ONE block pass (TWAP leaks — per test A). No
            // long idle gap before the push (that path trips an UNRELATED hook oracle-math overflow;
            // see the memo's secondary flag).
            _pushToward(pl, pl.quoteIsToken0 ? mags[k] : -mags[k]);
            vm.warp(block.timestamp + 120);

            uint256 treasuryNativeBefore = IERC20(pl.native).balanceOf(treasuryAddr);

            vm.recordLogs();
            (,, uint256 pf0, uint256 pf1) = vault.collectFees(pl.id, 0); // MUST NOT revert
            Vm.Log[] memory lg = vm.getRecordedLogs();

            (bool swapped,,) = _decodeSwapEvent(lg);
            uint256 nativePerf = pl.quoteIsToken0 ? pf1 : pf0;

            // INVARIANT across every manipulated collection on a shallow-history pool: the perf-fee
            // self-swap is NEVER even attempted — the oldestObservationAge gate (A) fires first.
            assertFalse(swapped, "perf-fee self-swap must NOT execute at the manipulated price");

            if (nativePerf > 0) {
                // The FULL native perf fee is preserved in-kind to treasury (fail-static): no value
                // is swapped away below its true worth.
                assertTrue(_hasEvent(lg, FALLBACK_SIG), "expected fail-static in-kind fallback");
                uint256 delivered = IERC20(pl.native).balanceOf(treasuryAddr) - treasuryNativeBefore;
                assertEq(delivered, nativePerf, "full native perf fee preserved in-kind to treasury (no value lost)");
                preservedDemonstrations++;
            }
        }
        assertGt(preservedDemonstrations, 0, "expected at least one nonzero-fee in-kind preservation");
    }

    /// @dev Founder-requested fuzz rigor (same treatment as OD-25): sweeps push magnitude AND the
    ///      elapsed time before collection continuously across the whole shallow-history regime
    ///      (under the 1800s gate), instead of 3 fixed points. On a shallow-history pool, the
    ///      self-swap must NEVER execute and the full native perf fee must ALWAYS be preserved
    ///      in-kind, regardless of exactly how far or how long ago the push was. Push direction is
    ///      fixed (native-cheap) — `_pushToward` only supports that one direction; magnitude and
    ///      elapsed time are what's fuzzed.
    function testFuzz_shallowHistory_alwaysFallsStaticInKind(int24 pushTicks, uint256 elapsedSec) public {
        pushTicks = int24(bound(pushTicks, 60, 3_000));
        elapsedSec = bound(elapsedSec, 1, FeraConstants.REBALANCE_TWAP_WINDOW_SEC - 1);

        Pool memory pl = _newPool("SHALLOW-FUZZ");
        _seed(pl);
        _generateNativeFee(pl, 2e18);
        _pushToward(pl, pl.quoteIsToken0 ? pushTicks : -pushTicks);
        vm.warp(block.timestamp + elapsedSec);

        (uint32 age, bool has) = hook.oldestObservationAge(pl.id);
        assertTrue(!has || age < FeraConstants.REBALANCE_TWAP_WINDOW_SEC, "precondition: still shallow history");

        uint256 treasuryNativeBefore = IERC20(pl.native).balanceOf(treasuryAddr);
        vm.recordLogs();
        (,, uint256 pf0, uint256 pf1) = vault.collectFees(pl.id, 0); // MUST NOT revert
        Vm.Log[] memory lg = vm.getRecordedLogs();
        (bool swapped,,) = _decodeSwapEvent(lg);
        uint256 nativePerf = pl.quoteIsToken0 ? pf1 : pf0;

        assertFalse(swapped, "shallow-history gate must ALWAYS block the swap attempt");
        if (nativePerf > 0) {
            assertTrue(_hasEvent(lg, FALLBACK_SIG), "expected fail-static in-kind fallback");
            uint256 delivered = IERC20(pl.native).balanceOf(treasuryAddr) - treasuryNativeBefore;
            assertEq(delivered, nativePerf, "full native perf fee must be preserved in-kind, always");
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // Control: an UN-manipulated collection routes through the bounded self-swap normally and lands
    // ~1:1 (quote out ≈ native in) — establishes that the fallback in (B) is caused by the
    // manipulation, not by the harness.
    // ═════════════════════════════════════════════════════════════════════════════════════════
    function test_control_unmanipulatedCollection_swapsNormally() public {
        Pool memory pl = _newPool("CTRL");
        _seed(pl);
        _generateNativeFee(pl, 2e18);
        vm.warp(block.timestamp + JIT + 1);

        vm.recordLogs();
        (,, uint256 pf0, uint256 pf1) = vault.collectFees(pl.id, 0);
        Vm.Log[] memory lg = vm.getRecordedLogs();
        (bool swapped, uint256 nativeIn, uint256 quoteOut) = _decodeSwapEvent(lg);
        uint256 nativePerf = pl.quoteIsToken0 ? pf1 : pf0;

        assertTrue(swapped, "control: the bounded self-swap should execute");
        assertEq(nativeIn, nativePerf, "control: swaps exactly the native perf fee");
        // ~1:1 pool ⇒ quote out within ~1% of native in (the bound the swap just cleared).
        assertApproxEqRel(quoteOut, nativeIn, 0.02e18, "control: quote out ~ native in at ~1:1 spot");
    }
}
