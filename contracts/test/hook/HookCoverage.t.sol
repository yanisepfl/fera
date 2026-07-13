// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockAggregatorV3} from "../utils/Mocks.sol";

import {FeraHook} from "../../src/FeraHook.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Coverage-focused hook tests over a REAL v4 PoolManager for the branches the acceptance
///         suites do not reach: the cumulative-tick TWAP ring rotation + read edges (R-23), the
///         `twapObservationAge` fail-closed input (REC-9), the decimals>18 oracle-normalization leg
///         (D-9), the MEME EWMA vol clamp, and the unconfigured-pool view fallbacks. All paths are
///         off the ≤40k swap budget (views) or exercised through genuine swaps.
contract HookCoverageTest is Deployers {
    using StateLibrary for IPoolManager;

    FeraHook internal hook;

    PoolKey internal mkey; // MEME
    PoolId internal mid;
    PoolKey internal rkey; // RWA
    PoolId internal rid;
    MockAggregatorV3 internal feed;

    int24 internal constant LO = -120_000;
    int24 internal constant HI = 120_000;

    function setUp() public {
        vm.warp(10_000_000); // realistic base time so ring timestamps are non-trivial
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0xC0FF) << 14));
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(this)), hookAddr);
        hook = FeraHook(hookAddr);

        mkey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        mid = mkey.toId();
        hook.registerRegime(mkey, FeraTypes.Regime.MEME);
        manager.initialize(mkey, SQRT_PRICE_1_1);
        _addLiq(mkey, 5_000_000e18);

        rkey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hookAddr));
        rid = rkey.toId();
        hook.registerRegime(rkey, FeraTypes.Regime.RWA);
        manager.initialize(rkey, SQRT_PRICE_1_1);
        _addLiq(rkey, 5_000_000e18);
    }

    function _addLiq(PoolKey memory k, uint256 L) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: LO, tickUpper: HI, liquidityDelta: int256(L), salt: 0}), ""
        );
    }

    function _swap(PoolKey memory k, bool zeroForOne, uint256 amtIn) internal {
        swap(k, zeroForOne, -int256(amtIn), "");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // TWAP ring — R-23 spacing-gated rotation. Swaps separated by ≥ SPACING freeze new ring slots
    // (the `nowTs - headBornTs >= SPACING` branch), so `consultTwapTick` reads across REAL time.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_twap_ringRotatesAcrossSpacingBoundaries_andConsults() public {
        // Fresh pool with no elapsed history yet ⇒ consult is NOT ready (same-block anchor).
        (, bool readyFresh) = hook.consultTwapTick(mid, 600);
        assertFalse(readyFresh, "fresh pool should not be TWAP-ready in-block");

        // Drive alternating swaps, each ≥ SPACING apart, so every write FREEZES a new ring slot and
        // the floating head advances — filling the ring and rotating the index. Use an explicit
        // accumulator so the warp target advances deterministically.
        uint256 t = block.timestamp;
        uint256 spacing = FeraConstants.TWAP_OBS_SPACING_SEC;
        for (uint256 i; i < 8; ++i) {
            t += spacing + 5;
            vm.warp(t);
            _swap(mkey, i % 2 == 0, 50_000e18);
        }

        // A window shorter than the accumulated real time finds a frozen anchor at-or-before target.
        (int24 twapTick, bool ready) = hook.consultTwapTick(mid, 300);
        assertTrue(ready, "TWAP not ready after ring rotation");

        // A window LONGER than all history ⇒ targetTs clamps to 0 ⇒ oldest-observation fallback anchor.
        (, bool readyLong) = hook.consultTwapTick(mid, type(uint32).max);
        assertTrue(readyLong, "long-window (oldest-anchor) read not ready");
        // Sanity: the averaged tick sits inside the traded tick band.
        assertGt(twapTick, -HI, "twap tick underflow");
        assertLt(twapTick, HI, "twap tick overflow");
    }

    // twapObservationAge: a live pool reports a small/zero age; an UNCONFIGURED pool has no obs.
    function test_twapObservationAge_liveVsUnobserved() public {
        _swap(mkey, true, 10_000e18); // seed/advance the head at `now`
        (uint32 age, bool has) = hook.twapObservationAge(mid);
        assertTrue(has, "observed pool should report hasObservation");
        assertEq(age, 0, "head just advanced => age 0");

        // A regime that was registered but whose pool was never initialized has no seeded observation.
        PoolKey memory ukey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 200, IHooks(address(hook)));
        (uint32 age2, bool has2) = hook.twapObservationAge(ukey.toId());
        assertFalse(has2, "unobserved pool must report no observation");
        assertEq(age2, 0, "no observation => age 0");
    }

    // Dormant pool: after a long gap the newest observation is stale (REC-9 fail-closed input).
    function test_twapObservationAge_reportsStalenessAfterDormancy() public {
        _swap(mkey, true, 10_000e18);
        vm.warp(block.timestamp + FeraConstants.TWAP_MAX_STALENESS_SEC + 100);
        (uint32 age, bool has) = hook.twapObservationAge(mid);
        assertTrue(has, "still has an observation");
        assertGt(age, FeraConstants.TWAP_MAX_STALENESS_SEC, "dormant pool age must exceed the staleness bound");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // Oracle decimals — D-9 per-feed decimals. The dec>18 normalization leg (answer / 10^(dec-18))
    // is exercised with a 20-decimal feed; the dec<18 leg is the common 8-decimal stock feed.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_oracle_decimalsGreaterThan18_normalizes() public {
        MockAggregatorV3 feed20 = new MockAggregatorV3(20);
        hook.setOracleFeed(rid, address(feed20));
        hook.setMarketOpen(rid, true);
        feed20.set(1e20, block.timestamp); // $1.00 at 20 decimals ⇒ matches the 1:1 pool ⇒ deviation ~0
        uint24 fee = hook.getDynamicFee(rid);
        assertEq(fee, FeraConstants.RWA_FEE_INHOURS_PIPS, "20-dec feed at parity should quote the open base");
    }

    function test_oracle_decimalsLessThan18_normalizes() public {
        feed = new MockAggregatorV3(8);
        hook.setOracleFeed(rid, address(feed));
        hook.setMarketOpen(rid, true);
        feed.set(1e8, block.timestamp);
        assertEq(hook.getDynamicFee(rid), FeraConstants.RWA_FEE_INHOURS_PIPS, "8-dec feed parity != open base");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // MEME EWMA — a violent alternating tick path saturates the realized-vol EWMA at MEME_VOL_CLAMP,
    // and the fee clamps at the ceiling (the `newVol > CLAMP` branch + the sigma>=sigmaAtCeil leg).
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_meme_extremeVolatility_clampsFeeAtCeiling() public {
        for (uint256 i; i < 12; ++i) {
            _swap(mkey, i % 2 == 0, 400_000e18); // large alternating swaps ⇒ huge |Δtick| ⇒ vol saturates
        }
        uint24 fee = hook.getDynamicFee(mid);
        (uint256 volX,,,) = hook.memeStateOf(mid);
        assertLe(fee, FeraConstants.MEME_FEE_CEIL_PIPS, "buy-side fee above ceiling");
        assertEq(fee, FeraConstants.MEME_FEE_CEIL_PIPS, "extreme vol should peg the buy-side fee at the ceiling");
        assertLe(volX, FeraConstants.MEME_VOL_CLAMP, "vol EWMA exceeded its clamp");
    }

    // getDynamicFee on an unconfigured (never-initialized) pool: regime reads MEME(0), state 0 ⇒ floor.
    function test_getDynamicFee_unconfiguredPool_returnsFloor() public view {
        PoolKey memory ukey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 200, IHooks(address(hook)));
        assertEq(hook.getDynamicFee(ukey.toId()), FeraConstants.MEME_FEE_FLOOR_PIPS, "unconfigured pool != MEME floor");
        assertFalse(hook.isConfigured(ukey.toId()), "unconfigured pool reported configured");
    }

    // isConfigured flips true once a pool is initialized through the hook.
    function test_isConfigured_afterInit() public view {
        assertTrue(hook.isConfigured(mid), "initialized MEME pool must be configured");
        assertTrue(hook.isConfigured(rid), "initialized RWA pool must be configured");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // onlyVault gating — the vault-driven config setters reject non-vault callers (INV-1″ init).
    // The test contract IS the vault, so a pranked stranger must revert.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_onlyVault_gatesConfigSetters() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(IFeraHook.OnlyVault.selector);
        hook.registerRegime(mkey, FeraTypes.Regime.MEME);
        vm.expectRevert(IFeraHook.OnlyVault.selector);
        hook.setMarketOpen(rid, true);
        vm.expectRevert(IFeraHook.OnlyVault.selector);
        hook.setSellIsZeroForOne(mid, false);
        vm.stopPrank();
    }

    // setSellIsZeroForOne toggles the MEME asymmetric-sell orientation bit (both ternary legs).
    function test_setSellIsZeroForOne_togglesOrientation() public {
        // Default orientation: zeroForOne == sell. Drive one-sided zeroForOne flow ⇒ that side is toxic.
        for (uint256 i; i < 6; ++i) {
            _swap(mkey, true, 150_000e18);
        }
        vm.prank(address(manager));
        (,, uint24 sellDefault) = hook.beforeSwap(address(this), mkey, _sp(true), "");
        vm.prank(address(manager));
        (,, uint24 buyDefault) = hook.beforeSwap(address(this), mkey, _sp(false), "");
        assertGt(sellDefault & ~uint24(LPFeeLibrary.OVERRIDE_FEE_FLAG), buyDefault & ~uint24(LPFeeLibrary.OVERRIDE_FEE_FLAG), "default: zeroForOne should be the surcharged sell");

        // Flip: now oneForZero (zeroForOne == false) is the toxic sell side.
        hook.setSellIsZeroForOne(mid, false);
        // And flip back (covers the other ternary leg).
        hook.setSellIsZeroForOne(mid, true);
    }

    // Transient RWA oracle cache — two RWA swaps in the SAME block: the first pays the cold read, a
    // later one may reuse the cached oracle value (PARAMS.md#RWA_ORACLE_TCACHE). Correctness is
    // identical whether cached or not; both swaps must execute (INV-2).
    function test_rwaOracleCache_twoSwapsSameBlock() public {
        feed = new MockAggregatorV3(8);
        hook.setOracleFeed(rid, address(feed));
        hook.setMarketOpen(rid, true);
        feed.set(102e6, block.timestamp); // slight deviation so the overlay engages
        BalanceDelta d1 = swap(rkey, true, -50_000e18, "");
        BalanceDelta d2 = swap(rkey, true, -50_000e18, ""); // same block ⇒ cache path may hit
        assertTrue(BalanceDelta.unwrap(d1) != 0 && BalanceDelta.unwrap(d2) != 0, "both RWA swaps must execute");
    }

    function _sp(bool zeroForOne) internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }
}
