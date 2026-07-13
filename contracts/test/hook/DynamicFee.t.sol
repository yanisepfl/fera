// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockAggregatorV3, RevertingAggregatorV3} from "../utils/Mocks.sol";

import {FeraHook} from "../../src/FeraHook.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice ACCEPTANCE — the dynamic fee now actually VARIES (the crown-jewel wiring).
///          MEME: a volatile tick path drives the fee above the floor, calm decays it back, and a
///                one-sided dump adds the asymmetric sell surcharge (sell fee > buy fee).
///          RWA:  the fee scales with |pool−oracle| deviation and clamps at 100bp; market-closed
///                widens the base; a stale/zero oracle returns the flat fail fee and the swap does
///                NOT revert (INV-2). All over a REAL v4 PoolManager.
contract DynamicFeeTest is Deployers {
    using StateLibrary for IPoolManager;

    FeraHook internal hook;

    // MEME pool
    PoolKey internal mkey;
    PoolId internal mid;
    // RWA pool
    PoolKey internal rkey;
    PoolId internal rid;
    MockAggregatorV3 internal feed;

    int24 internal constant LO = -120_000;
    int24 internal constant HI = 120_000;
    uint24 internal constant OVERRIDE = LPFeeLibrary.OVERRIDE_FEE_FLAG;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0xFEE1) << 14));
        // vault == this test contract (owns registerRegime / setOracleFeed / setMarketOpen).
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(this)), hookAddr);
        hook = FeraHook(hookAddr);

        // ── MEME pool ──
        mkey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        mid = mkey.toId();
        hook.registerRegime(mkey, FeraTypes.Regime.MEME);
        manager.initialize(mkey, SQRT_PRICE_1_1);
        _addLiq(mkey, 5_000_000e18);

        // ── RWA pool (different tickSpacing ⇒ distinct poolId, same currencies) ──
        rkey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hookAddr));
        rid = rkey.toId();
        hook.registerRegime(rkey, FeraTypes.Regime.RWA);
        manager.initialize(rkey, SQRT_PRICE_1_1);
        _addLiq(rkey, 5_000_000e18);

        feed = new MockAggregatorV3(8); // 8-decimal stock feed (D-9: decimals read, never assumed)
        hook.setOracleFeed(rid, address(feed));
        hook.setMarketOpen(rid, true);
        feed.set(1e8, block.timestamp); // $1.00 == pool 1:1 ⇒ deviation 0
    }

    function _addLiq(PoolKey memory k, uint256 L) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: LO, tickUpper: HI, liquidityDelta: int256(L), salt: 0}), ""
        );
    }

    function _swap(PoolKey memory k, bool zeroForOne, uint256 amtIn) internal {
        swap(k, zeroForOne, -int256(amtIn), "");
    }

    /// Read the directional fee the hook WOULD quote (strips the override flag), via a pranked
    /// beforeSwap as the manager — no state change to the pool, exercises the exact fee path.
    function _quote(PoolKey memory k, bool zeroForOne) internal returns (uint24) {
        vm.prank(address(manager));
        (, BeforeSwapDelta d, uint24 fee) = hook.beforeSwap(address(this), k, SwapParams(zeroForOne, -1e18, 0), "");
        BeforeSwapDelta.unwrap(d); // silence unused
        return fee & ~OVERRIDE;
    }

    function _tick(PoolId id) internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // MEME — the fee rises with realized volatility and decays back toward the floor when calm.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_meme_feeRisesWithVolatility_thenDecays() public {
        uint24 floorFee = FeraConstants.MEME_FEE_FLOOR_PIPS;

        // Calm baseline: freshly seeded EWMA (vol 0) ⇒ fee at the floor.
        uint24 calm0 = hook.getDynamicFee(mid);
        assertEq(calm0, floorFee, "fresh MEME pool should quote the floor");

        // Volatile burst: a couple of alternating swaps move the tick ⇒ sigma climbs ⇒ fee climbs
        // above the floor (kept moderate so the fee lands below the ceiling and decay is visible).
        _swap(mkey, true, 3_000e18);
        _swap(mkey, false, 3_000e18);
        uint24 volatile_ = hook.getDynamicFee(mid);
        (uint256 volPeak,,,) = hook.memeStateOf(mid);
        console2.log("MEME fee: calm(floor) =", calm0);
        console2.log("MEME fee: after volatile burst =", volatile_);
        assertGt(volatile_, floorFee, "MEME fee did not rise above floor with volatility");

        // Calm-down: many tiny swaps (near-zero tick move) ⇒ vol EWMA bleeds off (LAMBDA_DOWN=0.98).
        for (uint256 i; i < 60; ++i) {
            _swap(mkey, i % 2 == 0, 1e15);
        }
        uint24 afterCalm = hook.getDynamicFee(mid);
        (uint256 volAfter,,,) = hook.memeStateOf(mid);
        console2.log("MEME fee: after calm decay =", afterCalm);
        // The realized-vol EWMA strictly bled off (the mechanism), and the quoted fee followed it back
        // toward the floor.
        assertLt(volAfter, volPeak, "MEME realized-vol EWMA did not decay when calm");
        assertLt(afterCalm, volatile_, "MEME fee did not decay back toward the floor when calm");
        assertGe(afterCalm, floorFee, "MEME fee fell below the floor");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // MEME — one-sided dump adds the asymmetric sell surcharge: sell fee > buy fee.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_meme_sellSurchargeUnderOneSidedFlow() public {
        // Drive sustained one-sided SELL pressure (zeroForOne == sell, canonical orientation).
        for (uint256 i; i < 6; ++i) {
            _swap(mkey, true, 150_000e18);
        }
        uint24 buyFee = _quote(mkey, false); // buy-side base
        uint24 sellFee = _quote(mkey, true); // sell-side incl. adder
        console2.log("MEME one-sided flow: buy fee =", buyFee);
        console2.log("MEME one-sided flow: sell fee =", sellFee);
        assertGt(sellFee, buyFee, "sell-side surcharge absent under one-sided down flow");
        assertLe(sellFee, FeraConstants.MEME_FEE_HARD_MAX_PIPS, "sell fee above hard max");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // RWA — fee scales with oracle deviation and clamps at the 100bp ceiling.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_rwa_feeScalesWithDeviation_andClamps() public {
        // Deviation 0 ⇒ open base (200 pips).
        feed.set(1e8, block.timestamp);
        assertEq(hook.getDynamicFee(rid), FeraConstants.RWA_FEE_INHOURS_PIPS, "dev0 != open base");

        // Oracle 1% ABOVE pool (pool fixed at 1:1): dev = 0.01/1.01 ~= 99bps ⇒ ~200 + 20*99.
        feed.set(101e6, block.timestamp); // $1.01
        uint24 dev1 = hook.getDynamicFee(rid);
        console2.log("RWA fee @ ~1% deviation =", dev1);
        assertGt(dev1, FeraConstants.RWA_FEE_INHOURS_PIPS, "1% dev did not raise fee");
        assertApproxEqAbs(uint256(dev1), 2_180, 60, "1% dev fee off the +20pips/bp slope");

        // Oracle 3% above ⇒ dev ~291bps ⇒ 200 + 20*291 ~= 6020 (still < ceil).
        feed.set(103e6, block.timestamp);
        uint24 dev3 = hook.getDynamicFee(rid);
        console2.log("RWA fee @ ~3% deviation =", dev3);
        assertGt(dev3, dev1, "fee not monotonic in deviation");

        // Oracle 10% above ⇒ overlay blows past the ceiling ⇒ clamp at 100bp (10000 pips).
        feed.set(110e6, block.timestamp);
        uint24 devBig = hook.getDynamicFee(rid);
        console2.log("RWA fee @ ~10% deviation (clamped) =", devBig);
        assertEq(devBig, FeraConstants.RWA_FEE_CEIL_PIPS, "large dev did not clamp at ceiling");

        // Moving the POOL away from a fair oracle also raises the fee (the other side of |dev|).
        feed.set(1e8, block.timestamp); // back to fair
        assertEq(hook.getDynamicFee(rid), FeraConstants.RWA_FEE_INHOURS_PIPS, "reset dev0 failed");
        _swap(rkey, true, 300_000e18); // push pool price down, away from the oracle
        uint24 afterPoolMove = hook.getDynamicFee(rid);
        console2.log("RWA fee after pool moved off a fair oracle =", afterPoolMove);
        assertGt(afterPoolMove, FeraConstants.RWA_FEE_INHOURS_PIPS, "pool-vs-oracle gap did not raise fee");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // RWA — market closed widens the base fee.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_rwa_marketClosedWidensBase() public {
        feed.set(1e8, block.timestamp); // dev 0
        uint24 openFee = hook.getDynamicFee(rid);
        hook.setMarketOpen(rid, false);
        uint24 closedFee = hook.getDynamicFee(rid);
        console2.log("RWA base: open =", openFee);
        console2.log("RWA base: closed =", closedFee);
        assertEq(openFee, FeraConstants.RWA_FEE_INHOURS_PIPS, "open base wrong");
        assertEq(closedFee, FeraConstants.RWA_FEE_OFFHOURS_PIPS, "closed base did not widen");
        assertGt(closedFee, openFee, "closed base not wider than open");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // RWA — a stale (in-hours) or zero oracle returns the flat fail fee and the swap does NOT revert.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_rwa_staleOracleFailFee_swapDoesNotRevert() public {
        vm.warp(block.timestamp + 10 days); // give room for a stale updatedAt

        // In-hours staleness beyond RWA_STALE_AFTER_OPEN_SEC ⇒ fail fee.
        hook.setMarketOpen(rid, true);
        feed.set(1e8, block.timestamp - FeraConstants.RWA_STALE_AFTER_OPEN_SEC - 1);
        assertEq(hook.getDynamicFee(rid), FeraConstants.RWA_ORACLE_FAIL_FEE_PIPS, "stale in-hours != fail fee");

        // Zero answer ⇒ fail fee, regardless of hours.
        feed.set(0, block.timestamp);
        assertEq(hook.getDynamicFee(rid), FeraConstants.RWA_ORACLE_FAIL_FEE_PIPS, "zero answer != fail fee");

        // And a REAL swap against the dead oracle MUST still execute (INV-2: never revert for oracle fail).
        BalanceDelta d = swap(rkey, true, -1_000e18, "");
        assertTrue(BalanceDelta.unwrap(d) != 0, "swap did not execute against a dead oracle");

        // Off-hours staleness is EXPECTED and is NOT a failure (feed only prints in-hours): the fee is
        // the closed base + any deviation overlay, NOT the flat fail fee.
        hook.setMarketOpen(rid, false);
        feed.set(1e8, block.timestamp - FeraConstants.RWA_STALE_AFTER_OPEN_SEC - 1);
        uint24 offHoursStale = hook.getDynamicFee(rid);
        console2.log("RWA off-hours + stale feed (healthy) fee =", offHoursStale);
        assertGe(offHoursStale, FeraConstants.RWA_FEE_OFFHOURS_PIPS, "off-hours base below closed base");
        assertLt(offHoursStale, FeraConstants.RWA_ORACLE_FAIL_FEE_PIPS, "off-hours staleness wrongly failed to blind fee");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // COV-1 — a feed that REVERTS on latestRoundData() is caught (try/catch) ⇒ blind/fail fee,
    // and the swap still executes (INV-2: a broken oracle NEVER reverts a swap).
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_rwa_feedReverts_failFee_swapDoesNotRevert() public {
        RevertingAggregatorV3 badFeed = new RevertingAggregatorV3();
        hook.setOracleFeed(rid, address(badFeed));
        hook.setMarketOpen(rid, true); // in-hours ⇒ an unavailable oracle maps to the flat fail fee

        // The view path (getDynamicFee) exercises _oraclePriceX96's catch leg and must not revert.
        assertEq(hook.getDynamicFee(rid), FeraConstants.RWA_ORACLE_FAIL_FEE_PIPS, "reverting feed != fail fee");

        // The live swap path (_oraclePriceX96Cached → _oraclePriceX96 catch) must also execute.
        BalanceDelta d = swap(rkey, true, -1_000e18, "");
        assertTrue(BalanceDelta.unwrap(d) != 0, "swap reverted on a broken feed (INV-2 violated)");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // Market-hours: the 168-bit UTC calendar bounds the keeper flag (open ⇔ schedule AND flag).
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_rwa_scheduleBoundsKeeper() public {
        hook.setMarketOpen(rid, true);
        // Compute the current hour-of-week and set a calendar that CLOSES exactly this hour.
        uint256 hourOfWeek = (block.timestamp / 3_600) % 168;
        uint256 allOpen = type(uint256).max;
        hook.setSchedule(rid, allOpen & ~(uint256(1) << hourOfWeek)); // open every hour EXCEPT now
        assertFalse(hook.isMarketOpen(rid), "schedule failed to close the market this hour");
        feed.set(1e8, block.timestamp);
        assertEq(hook.getDynamicFee(rid), FeraConstants.RWA_FEE_OFFHOURS_PIPS, "calendar-closed base not widened");

        // Holiday force-closes even with the flag on and an all-open calendar.
        hook.setSchedule(rid, allOpen);
        assertTrue(hook.isMarketOpen(rid), "all-open calendar should be open");
        hook.setHoliday(rid, true);
        assertFalse(hook.isMarketOpen(rid), "holiday did not force-close");
    }
}
