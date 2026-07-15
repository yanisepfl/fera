// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
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
import {MintableERC20, HostileNativeERC20} from "../utils/Mocks.sol";

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

/// @notice v3.1 UNIFIED FEE-ROUTING (contracts/VAULT_STRATEGY_V3.md §9). Covers the full decided
///         spec exactly as tasked:
///          1. both sides already reward-token-allowlisted (e.g. a WETH/USDG-shaped pool) ⇒
///             no-swap path — gas-cheapest, no swap event.
///          2. native side NOT allowlisted ⇒ the bounded self-swap fires (reusing the EXACT same
///             primitive rebalancing uses), spending ONLY this pool's own collected fee, and the
///             realized quote amount lands 50/25/25.
///          3. a thin/hostile pool where the self-swap would exceed MAX_REBALANCE_SLIPPAGE_BPS ⇒
///             FAIL-STATIC in-kind forward to treasury; collectFees never reverts.
///          4. a hostile reverting native token (every vault-originated transfer of it reverts,
///             including the fallback itself) ⇒ collectFees STILL never bricks.
///          5. zero-staked-yet ⇒ the would-be stakers' share reroutes to treasury; once staked,
///             the NEXT collection routes to stakers normally.
contract UnifiedFeeRoutingTest is Deployers {
    using StateLibrary for IPoolManager;

    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    AnchorStaking internal staking;
    FeraShare internal shareImpl;
    MintableERC20 internal stakeToken;

    address internal treasuryAddr = makeAddr("treasury");
    address internal opsAddr = makeAddr("ops");
    address internal alice = makeAddr("alice");

    PoolKey internal feeKey; // currency0 = QUOTE, currency1 = NATIVE (quoteIsToken0 = true)
    PoolId internal feeId;

    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant COOLDOWN = 3_600;
    uint256 internal constant JIT = 1_800;

    bytes32 internal constant SWAPPED_SIG = keccak256("PerfFeeSwapped(bytes32,uint8,address,uint256,address,uint256)");
    bytes32 internal constant FALLBACK_SIG = keccak256("PerfFeeInKindFallback(bytes32,uint8,address,uint256,bool)");

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies(); // currency0/currency1 — standard, well-behaved tokens

        shareImpl = new FeraShare();
        stakeToken = new MintableERC20("STK", "STK");

        // Break the AnchorStaking<->RevenueDistributor ctor cycle (predict staking's address).
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

        feeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        // v3.3 permissionless creation: team-curation lever must be set before pool creation.
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        // quoteIsToken0 = true: currency0 is the liquid quote asset, currency1 the native/project token.
        feeId = vault.createBaseLimitPool(feeKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "FEE", "F");

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);

        stakeToken.mint(alice, 1_000e18);
    }

    // ── helpers ────────────────────────────────────────────────────────────────────────────
    function _quote() internal view returns (address) {
        return Currency.unwrap(currency0);
    }

    function _native() internal view returns (address) {
        return Currency.unwrap(currency1);
    }

    function _seed() internal {
        vault.deposit(feeId, 0, 1_000e18, 1_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT);
        _refreshTwap();
    }

    function _refreshTwap() internal {
        swap(feeKey, true, -1e15, "");
        swap(feeKey, false, -1e15, "");
    }

    /// Generate a real native-side (token1-input) LP fee via a modest swap.
    function _generateNativeFee(uint256 amt) internal {
        swap(feeKey, false, -int256(amt), ""); // input = token1 = native ⇒ fee accrues in token1
    }

    /// Generate a real quote-side (token0-input) LP fee via a modest swap.
    function _generateQuoteFee(uint256 amt) internal {
        swap(feeKey, true, -int256(amt), ""); // input = token0 = quote ⇒ fee accrues in token0
    }

    function _stakeSome() internal {
        vm.startPrank(alice);
        stakeToken.approve(address(staking), 100e18);
        staking.stake(100e18);
        vm.stopPrank();
    }

    function _pushToTick(PoolKey memory key, PoolId id, int24 target) internal {
        (, int24 tick,,) = manager.getSlot0(id);
        bool up = target > tick;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !up,
                amountSpecified: -int256(5_000_000e18),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _addDeepExternalLiquidity(PoolKey memory key, PoolId id) internal {
        (uint160 sp0,,,) = manager.getSlot0(id);
        int24 lo = -24_000;
        int24 hi = 24_000;
        uint128 extL = LiquidityAmounts.getLiquidityForAmounts(
            sp0, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), 5_000_000e18, 5_000_000e18
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(extL)), salt: bytes32("ext")}),
            ""
        );
    }

    function _pending(address who, address token) internal view returns (uint256) {
        return rev.pending(who, token);
    }

    function _decodeSwapEvent(Vm.Log[] memory logs) internal pure returns (bool found, uint256 nativeIn, uint256 quoteOut) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == SWAPPED_SIG) {
                (, address nativeToken, uint256 nIn, address quoteToken, uint256 qOut) =
                    abi.decode(logs[i].data, (uint8, address, uint256, address, uint256));
                nativeToken; quoteToken;
                found = true;
                nativeIn = nIn;
                quoteOut = qOut;
            }
        }
    }

    function _decodeFallbackEvent(Vm.Log[] memory logs) internal pure returns (bool found, uint256 amount, bool forwarded) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == FALLBACK_SIG) {
                (, , uint256 amt, bool fwd) = abi.decode(logs[i].data, (uint8, address, uint256, bool));
                found = true;
                amount = amt;
                forwarded = fwd;
            }
        }
    }

    function _hasEvent(Vm.Log[] memory logs, bytes32 sig) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) return true;
        }
        return false;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 1) BOTH SIDES ALLOWLISTED ⇒ no-swap path, gas-cheapest, no swap event
    // ═════════════════════════════════════════════════════════════════════════════════════
    function test_bothAllowlisted_noSwap_cheaperAndNoSwapEvent() public {
        _seed();

        // First: native NOT yet allowlisted ⇒ the swap path fires (measure its gas + events).
        staking.addRewardToken(_quote());
        _generateNativeFee(2e18);
        vm.warp(block.timestamp + JIT + 1);
        vm.recordLogs();
        uint256 gasBeforeSwap = gasleft();
        vault.collectFees(feeId, 0);
        uint256 gasSwapPath = gasBeforeSwap - gasleft();
        Vm.Log[] memory logsSwap = vm.getRecordedLogs();
        assertTrue(_hasEvent(logsSwap, SWAPPED_SIG), "expected the swap path to fire while native is unlisted");

        // Now allowlist native too ⇒ BOTH sides allowlisted ⇒ no-swap path.
        staking.addRewardToken(_native());
        _generateNativeFee(2e18);
        vm.warp(block.timestamp + JIT + 1);
        vm.recordLogs();
        uint256 gasBeforeNoSwap = gasleft();
        vault.collectFees(feeId, 0);
        uint256 gasNoSwapPath = gasBeforeNoSwap - gasleft();
        Vm.Log[] memory logsNoSwap = vm.getRecordedLogs();
        assertFalse(_hasEvent(logsNoSwap, SWAPPED_SIG), "no-swap path must not emit PerfFeeSwapped");
        assertFalse(_hasEvent(logsNoSwap, FALLBACK_SIG), "no-swap path must not emit PerfFeeInKindFallback");

        assertLt(gasNoSwapPath, gasSwapPath, "no-swap path should be cheaper than the swap path (no extra unlock+swap)");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 2) NATIVE SIDE NEEDS SWAPPING ⇒ bounded self-swap fires; 50/25/25 lands on the REALIZED
    //    quote amount; the swap spends ONLY this pool's own collected native fee.
    // ═════════════════════════════════════════════════════════════════════════════════════
    function test_nativeNeedsSwap_boundedSelfSwapFires_correctSplitLands() public {
        _seed();
        _stakeSome(); // nonzero totalStaked ⇒ exercise the NORMAL (not no-staker) split

        staking.addRewardToken(_quote()); // quote allowlisted, native NOT ⇒ forces the swap path
        _generateNativeFee(2e18);
        vm.warp(block.timestamp + JIT + 1);

        vm.recordLogs();
        (,, uint256 perfFee0, uint256 perfFee1) = vault.collectFees(feeId, 0);
        assertGt(perfFee1, 0, "expected a nonzero native-side perf fee to swap");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, uint256 nativeIn, uint256 quoteOut) = _decodeSwapEvent(logs);
        assertTrue(found, "expected PerfFeeSwapped");
        assertEq(nativeIn, perfFee1, "self-swap must spend EXACTLY the native perf fee collected from this pool");

        uint256 totalQuote = perfFee0 + quoteOut;
        uint256 expStakers = (totalQuote * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS;
        uint256 expTreasury = (totalQuote * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS;
        uint256 expOps = totalQuote - expStakers - expTreasury;

        assertEq(_pending(address(staking), _quote()), expStakers, "stakers 50% mismatch");
        assertEq(_pending(treasuryAddr, _quote()), expTreasury, "treasury 25% mismatch");
        assertEq(_pending(opsAddr, _quote()), expOps, "ops 25% mismatch");
        // Nothing was routed for the native token itself (it was fully swapped away).
        assertEq(_pending(address(staking), _native()), 0, "unexpected native-side stakers credit");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 3) THIN/HOSTILE POOL: the self-swap's TWAP-implied bound is exceeded (same-block huge
    //    price push the 30-min TWAP hasn't caught up with yet — the IDENTICAL on-chain condition
    //    a genuinely thin pool trips) ⇒ FAIL-STATIC in-kind forward to treasury; collectFees NEVER
    //    reverts.
    // ═════════════════════════════════════════════════════════════════════════════════════
    function test_slippageExceeded_failStaticInKindToTreasury_collectFeesNeverReverts() public {
        _seed();
        staking.addRewardToken(_quote()); // native NOT allowlisted ⇒ forces the swap attempt

        _generateNativeFee(2e18);

        // Same-block manipulation: the TWAP cannot move within this block (R-23/V2-2), so pushing
        // spot far away desyncs the self-swap's TWAP-implied minOut from the ACTUAL execution price.
        _addDeepExternalLiquidity(feeKey, feeId);
        _pushToTick(feeKey, feeId, 20_000); // ~e^2 ≈ 7.4x price move, same block ⇒ TWAP lags behind

        uint256 treasuryNativeBefore = IERC20(_native()).balanceOf(treasuryAddr);

        vm.recordLogs();
        (,,, uint256 perfFee1) = vault.collectFees(feeId, 0); // MUST NOT revert
        assertGt(perfFee1, 0, "expected a nonzero native-side perf fee");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, uint256 amount, bool forwarded) = _decodeFallbackEvent(logs);
        assertTrue(found, "expected PerfFeeInKindFallback");
        assertTrue(forwarded, "the plain (non-hostile) native token's transfer should succeed");
        assertEq(amount, perfFee1, "fallback amount must equal the collected native perf fee");

        uint256 treasuryNativeAfter = IERC20(_native()).balanceOf(treasuryAddr);
        assertEq(treasuryNativeAfter - treasuryNativeBefore, perfFee1, "treasury did not receive the FULL in-kind native fee");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 4) HOSTILE REVERTING NATIVE TOKEN: every vault-originated transfer of the native token
    //    reverts (both the self-swap's settle AND the in-kind fallback forward) ⇒ collectFees
    //    STILL never bricks.
    // ═════════════════════════════════════════════════════════════════════════════════════
    function test_hostileRevertingNativeToken_collectFeesNeverBricks() public {
        (PoolId hid, PoolKey memory hkey, HostileNativeERC20 hostile, address quote, bool hostileIsToken0) =
            _createHostilePool();

        vault.deposit(hid, 0, 1_000e18, 1_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT);
        swap(hkey, true, -1e15, "");
        swap(hkey, false, -1e15, "");

        staking.addRewardToken(quote); // hostile native NOT allowlisted ⇒ forces the swap attempt

        // Generate a real native-side fee: input the NATIVE token.
        swap(hkey, hostileIsToken0, -2e18, "");
        vm.warp(block.timestamp + JIT + 1);

        hostile.setBlockedSender(address(vault)); // arm the hostility AFTER funding is already in

        uint256 treasuryBefore = hostile.balanceOf(treasuryAddr);
        uint256 vaultBefore = hostile.balanceOf(address(vault));

        vm.recordLogs();
        (, , uint256 perfFee0, uint256 perfFee1) = vault.collectFees(hid, 0); // MUST NOT revert
        uint256 nativePerfFee = hostileIsToken0 ? perfFee0 : perfFee1;
        assertGt(nativePerfFee, 0, "expected a nonzero hostile native-side perf fee");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, uint256 amount, bool forwarded) = _decodeFallbackEvent(logs);
        assertTrue(found, "expected PerfFeeInKindFallback");
        assertFalse(forwarded, "the hostile token's own fallback transfer should itself fail");
        assertEq(amount, nativePerfFee, "reported fallback amount mismatch");

        // Treasury received NOTHING (the raw fallback transfer failed) — but collectFees survived.
        assertEq(hostile.balanceOf(treasuryAddr), treasuryBefore, "treasury should NOT have received the hostile token");
        // The fee WAS realized from the pool (a plain `.take()` FROM the poolManager, unaffected by
        // `blockedSender` since that only blocks transfers FROM the Vault) but then could leave
        // neither via the swap nor the fallback — so it simply remains in the Vault's own balance,
        // never lost, never bricking collection.
        assertGe(
            hostile.balanceOf(address(vault)), vaultBefore + nativePerfFee, "hostile native perf fee should remain stranded in the vault"
        );
    }

    /// @notice Companion hostile shape: a fee-on-transfer native token. The fallback transfer
    ///         itself SUCCEEDS (no revert) but delivers less than the nominal amount — still never
    ///         bricks collectFees, and treasury receives whatever the token actually delivered.
    function test_feeOnTransferNativeToken_fallbackDeliversLessButNeverBricks() public {
        (PoolId hid, PoolKey memory hkey, HostileNativeERC20 hostile, address quote, bool hostileIsToken0) =
            _createHostilePool();

        vault.deposit(hid, 0, 1_000e18, 1_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT);
        swap(hkey, true, -1e15, "");
        swap(hkey, false, -1e15, "");

        staking.addRewardToken(quote);
        swap(hkey, hostileIsToken0, -2e18, "");
        vm.warp(block.timestamp + JIT + 1);

        // Force the swap attempt to fail (so the fallback path is the one under test) via a huge
        // same-block price push in the direction that makes selling NATIVE for QUOTE underperform
        // the (stale) TWAP: pushing DOWN when native==token0 (selling token0 lowers its own price),
        // pushing UP when native==token1 (selling token1 raises price, lowering token1's own value).
        _addDeepExternalLiquidity(hkey, hid);
        _pushToTick(hkey, hid, hostileIsToken0 ? int24(-20_000) : int24(20_000));
        hostile.setFeeBps(1_000); // 10% burned on every transfer

        uint256 treasuryBefore = hostile.balanceOf(treasuryAddr);

        (, , uint256 perfFee0, uint256 perfFee1) = vault.collectFees(hid, 0); // MUST NOT revert
        uint256 nativePerfFee = hostileIsToken0 ? perfFee0 : perfFee1;
        assertGt(nativePerfFee, 0, "expected a nonzero native-side perf fee");

        uint256 delivered = hostile.balanceOf(treasuryAddr) - treasuryBefore;
        assertGt(delivered, 0, "fee-on-transfer fallback delivered nothing");
        assertLt(delivered, nativePerfFee, "fee-on-transfer token should deliver LESS than the nominal amount");
    }

    function _createHostilePool()
        internal
        returns (PoolId id, PoolKey memory key, HostileNativeERC20 hostile, address quote, bool hostileIsToken0)
    {
        MintableERC20 quoteToken = new MintableERC20("QUOTE", "Q");
        hostile = new HostileNativeERC20("NATIVE", "N");
        quote = address(quoteToken);

        quoteToken.mint(address(this), 20_000_000e18);
        hostile.mint(address(this), 20_000_000e18);
        quoteToken.approve(address(vault), type(uint256).max);
        hostile.approve(address(vault), type(uint256).max);
        quoteToken.approve(address(swapRouter), type(uint256).max);
        hostile.approve(address(swapRouter), type(uint256).max);
        quoteToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        hostile.approve(address(modifyLiquidityRouter), type(uint256).max);

        bool quoteIsC0 = address(quoteToken) < address(hostile);
        hostileIsToken0 = !quoteIsC0;
        Currency c0 = quoteIsC0 ? Currency.wrap(address(quoteToken)) : Currency.wrap(address(hostile));
        Currency c1 = quoteIsC0 ? Currency.wrap(address(hostile)) : Currency.wrap(address(quoteToken));
        key = PoolKey({currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(address(hook))});
        // v3.3 permissionless creation: team-curation lever must be set before pool creation (this
        // pool's quote token is freshly minted per-call, so it must be allowlisted each time too).
        vault.setAllowedQuoteAsset(quote, true);
        id = vault.createBaseLimitPool(key, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, quoteIsC0, "HOSTILE", "H");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 5) ZERO-STAKED-YET ⇒ the 50% staker share routes to treasury; once staked, the NEXT
    //    collection routes to stakers normally.
    // ═════════════════════════════════════════════════════════════════════════════════════
    function test_zeroStaked_routesToTreasury_thenStakersOnceStaked() public {
        _seed();
        // Stage-3 (contracts/VAULT_STRATEGY_V3.md §10 / OPEN_DECISIONS.md#OD-9): the treasury is
        // now a PLAIN EOA — RevenueDistributor's `treasury` immutable must be exactly that address
        // (no bytecode), never a Treasury.sol (or any other) contract instance. `treasuryAddr` here
        // is a bare `makeAddr` EOA stand-in, exactly mirroring how `script/Deploy.s.sol` wires
        // FERA_TREASURY_EOA directly (RevenueDistributor never assumes anything about what its
        // `treasury` recipient is — see §9.4).
        assertEq(treasuryAddr.code.length, 0, "treasury recipient must be a plain EOA (no bytecode)");
        assertEq(rev.treasury(), treasuryAddr, "RevenueDistributor.treasury must equal the configured EOA");

        // Both sides allowlisted ⇒ the simplest (no-swap) split path, isolating the no-staker branch.
        staking.addRewardToken(_quote());
        staking.addRewardToken(_native());
        assertEq(staking.totalStaked(), 0, "expected zero staked at genesis");

        _generateQuoteFee(2e18);
        vm.warp(block.timestamp + JIT + 1);
        (, , uint256 perfFee0a, uint256 perfFee1a) = vault.collectFees(feeId, 0);
        perfFee1a;
        assertGt(perfFee0a, 0, "expected a nonzero quote-side perf fee on the first collection");

        // No-staker routing: stakers got 0; treasury absorbed the stakers' 50% AND its own 25%;
        // ops is UNAFFECTED (its 25% leg routes identically regardless of staking state).
        assertEq(_pending(address(staking), _quote()), 0, "stakers must get 0 while totalStaked==0");
        assertEq(_pending(address(staking), _native()), 0, "stakers must get 0 while totalStaked==0");
        uint256 expTreasury0 =
            (perfFee0a * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS + (perfFee0a * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS;
        uint256 expOps0 = perfFee0a - expTreasury0;
        assertEq(_pending(treasuryAddr, _quote()), expTreasury0, "treasury must absorb EXACTLY the stakers' 50% plus its own 25%");
        assertEq(_pending(opsAddr, _quote()), expOps0, "ops share must be routed normally (unaffected by no-staker routing)");

        // Now stake something.
        _stakeSome();
        assertGt(staking.totalStaked(), 0, "expected nonzero staked after alice stakes");

        // Generate MORE fees and collect again — this second collection must route to stakers.
        uint256 stakersQuoteBefore = _pending(address(staking), _quote());
        uint256 treasuryQuoteBefore = _pending(treasuryAddr, _quote());
        _generateQuoteFee(2e18);
        vm.warp(block.timestamp + JIT + 1);
        (, , uint256 perfFee0b,) = vault.collectFees(feeId, 0);
        assertGt(perfFee0b, 0, "expected a nonzero quote-side perf fee on the second collection");

        uint256 expStakersDelta = (perfFee0b * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS;
        uint256 expTreasuryDelta = (perfFee0b * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS;
        assertEq(
            _pending(address(staking), _quote()) - stakersQuoteBefore,
            expStakersDelta,
            "stakers should receive their 50% now that totalStaked > 0"
        );
        assertEq(
            _pending(treasuryAddr, _quote()) - treasuryQuoteBefore,
            expTreasuryDelta,
            "treasury should receive only its normal 25% now that stakers are eligible again"
        );
    }
}
