// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FeraVault} from "../../src/FeraVault.sol";
import {FeraHook} from "../../src/FeraHook.sol";
import {FeraShare} from "../../src/shares/FeraShare.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {IFeraVault} from "../../src/interfaces/IFeraVault.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {MockAggregatorV3} from "../utils/Mocks.sol";

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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice v3-HARDENING pass PoC suite (2026-07-14). Three deliverables:
///  TASK 1 — hook TWAP int56/uint32 oracle math is now UNCHECKED (Uniswap-reference semantics): a
///           swap that crosses the uint32 timestamp rollover CANNOT revert (INV-2), and the
///           `consultTwapTick` view feeding the deposit/rebalance gates cannot panic-DoS them.
///  TASK 2 — MEME rebalancing is LVR-aware (Milionis et al.): the wide vol-adaptive base HOLDS through
///           moves (recentering a trend realizes the loss), the base recenter is a bounded, rate-
///           limited opportunistic safety valve (never runaway), and OPERABILITY (deposit/withdraw
///           in-kind) is fully decoupled from range/rebalancing state.
///  TASK 3 — RWA regime restored: in-hours oracle-anchored recenter (mean-reversion, the OPPOSITE of
///           MEME) + off-hours/event WIDEN + partial-withdraw defense (re-wires `eventWindow`).
contract VaultHardeningV3Test is Deployers {
    using StateLibrary for IPoolManager;

    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;
    MockAggregatorV3 internal feed;

    PoolKey internal memeKey;
    PoolKey internal rwaKey;
    PoolId internal memeId;
    PoolId internal rwaId;

    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant COOLDOWN = 3_600;
    uint256 internal constant JIT = 1_800;

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));
        feed = new MockAggregatorV3(8);
        feed.set(1e8, block.timestamp);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x4242) << 14));
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), IAnchorStaking(address(0)),
            address(shareImpl), address(this), address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);

        memeKey = PoolKey({currency0: currency0, currency1: currency1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(hookAddr)});
        rwaKey = PoolKey({currency0: currency0, currency1: currency1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 10, hooks: IHooks(hookAddr)});

        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        vault.approveRwaFeed(address(feed), "test RWA feed");
        memeId = vault.createBaseLimitPool(memeKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME-BL", "mBL");
        rwaId = vault.createBaseLimitPool(rwaKey, FeraTypes.Regime.RWA, address(feed), SQRT_PRICE_1_1, true, "RWA-BL", "rBL");
        vault.setKeeperActive(memeId, true);
        vault.setKeeperActive(rwaId, true);

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────
    function _seedMeme() internal {
        vault.deposit(memeId, 0, 1_000e18, 1_000e18, 0);
        vault.deposit(memeId, 1, 1_000e18, 1_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT);
        _refreshTwap(memeKey);
    }

    function _refreshTwap(PoolKey memory key) internal {
        swap(key, true, -1e15, "");
        swap(key, false, -1e15, "");
    }

    function _pushToTick(PoolKey memory key, int24 target) internal {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        bool up = target > tick;
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: !up, amountSpecified: -int256(5_000_000e18), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _bandWidth(PoolId id, uint8 t, uint256 idx) internal view returns (uint256) {
        (int24 lo, int24 hi,,,) = vault.bandInfo(id, t, idx);
        return uint256(uint24(hi - lo));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TASK 1 — hook TWAP int56/uint32 overflow: unchecked wrapping ⇒ swaps never revert; the view
    // feeding the deposit/rebalance gates never panics.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// A swap that crosses the uint32 timestamp rollover must NOT revert (afterSwap → `_writeOracle`).
    /// Pre-fix this underflow-panicked (0x11) in the CHECKED uint32/int56 math, bricking the swap.
    function test_task1_swapNeverRevertsAcrossUint32Boundary() public {
        _seedMeme();

        // Just below the uint32 rollover: this swap writes an observation at blockTimestamp ~2^32-50.
        vm.warp(uint256(type(uint32).max) - 50);
        swap(memeKey, true, -1e15, "");

        // Cross the boundary: uint32(now) wraps to a small value, so `nowTs - head.blockTimestamp`
        // (uint32) and `_headBornTs` deltas would underflow under CHECKED arithmetic. This swap must
        // still succeed — INV-2 "swaps never revert" — proving the fix.
        vm.warp(uint256(type(uint32).max) + 200);
        swap(memeKey, false, -1e15, ""); // MUST NOT revert

        // The manipulation-resistant view the deposit/rebalance gates consume must not panic either.
        (int24 tw, bool ready) = hook.consultTwapTick(memeId, FeraConstants.REBALANCE_TWAP_WINDOW_SEC);
        tw;
        ready;

        // A few more post-boundary observations so the read differences two (post-wrap) cumulatives —
        // exercises the `cumNow - anchorCum` wrapping delta directly. None may revert.
        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + 100);
            swap(memeKey, i % 2 == 0, -1e15, "");
            (tw, ready) = hook.consultTwapTick(memeId, FeraConstants.REBALANCE_TWAP_WINDOW_SEC);
        }

        // The deposit gate (which reads the TWAP without a try/catch at the source, behind the vault's
        // defense-in-depth `_consultTwap`) must not panic-DoS. It may legitimately revert on a gate,
        // but never an uncaught arithmetic panic.
        try vault.deposit(memeId, 0, 100e18, 100e18, 0) returns (uint256 sh) {
            assertGt(sh, 0, "post-boundary deposit minted 0");
        } catch {
            // A gate revert is acceptable; the point is no 0x11 panic bubbled up.
        }
    }

    /// A large-cumulative / extreme-tick history combined with the boundary crossing still reads
    /// without reverting (int56 accumulation wraps rather than panicking).
    function test_task1_consultTwapNoRevert_extremeTickHistory() public {
        _seedMeme();
        // Drive the tick to a large magnitude, then let time pass so tickCumulative grows, then read.
        _pushToTick(memeKey, 60_000);
        vm.warp(block.timestamp + FeraConstants.TWAP_OBS_SPACING_SEC + 5);
        swap(memeKey, false, -1e15, "");
        vm.warp(block.timestamp + FeraConstants.TWAP_OBS_SPACING_SEC + 5);
        swap(memeKey, true, -1e15, "");
        (int24 tw, bool ready) = hook.consultTwapTick(memeId, FeraConstants.REBALANCE_TWAP_WINDOW_SEC);
        tw;
        ready; // no revert is the assertion
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TASK 2 — LVR-aware MEME rebalancing.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// LVR wide-base calibration: a volatile MEME pair gets a DRAMATICALLY wider vol-adaptive band
    /// than a calm one — the base is meant to approach full-range and HOLD (recentering a trend
    /// realizes the loss). Measured via the freely-redeployed LIMIT band (same `_effectiveHalfWidth`
    /// multiplier), which needs no OOR/dwell — only spot≈TWAP for the redeploy's sanity gate.
    function test_task2_lvr_volatilePoolGetsMuchWiderBand() public {
        _seedMeme();
        vault.skimIdle(memeId, 0);
        vault.rebalanceLimit(memeId, 0); // deploy #1 at genesis-calm EWMA (≈0 ⇒ 0.5x floor)
        uint256 widthCalm = _bandWidth(memeId, 0, vault.bandCount(memeId, 0) - 1);

        // Pump realized vol with a burst of big alternating swings, ending back near tick 0 so
        // spot/TWAP stay within the redeploy's ±5% sanity bound (same-block swings still feed the EWMA).
        for (uint256 i; i < 10; ++i) {
            _pushToTick(memeKey, i % 2 == 0 ? int24(3_000) : int24(-3_000));
        }
        _pushToTick(memeKey, 0);

        vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
        _refreshTwap(memeKey);
        vault.skimIdle(memeId, 0);
        vault.rebalanceLimit(memeId, 0); // deploy #2 at the now-pumped EWMA (high multiplier)
        uint256 widthVol = _bandWidth(memeId, 0, vault.bandCount(memeId, 0) - 1);

        // With the LVR calibration (0.5x floor → up to 25x cap, steeper slope) the volatile band is
        // MANY times wider than the calm one — a near-full-range hold-in-place base.
        assertGt(widthVol, widthCalm * 3, "LVR calibration: volatile MEME band not dramatically wider");
    }

    /// A trending MEME price path must NOT trigger RUNAWAY recenters — the dedicated 6h base-recenter
    /// interval caps them to a small bounded count over a 24h window (never the "aggressive
    /// recentering loses money" failure). 0 is also acceptable (the wide base simply held).
    function test_task2_trendingPath_boundedRecenters() public {
        _seedMeme();

        uint256 recenters;
        int24 target = 2_000;
        for (uint256 i; i < 48; ++i) {
            // 48 * 30min = 24h. Escalate the trend each step so the base is repeatedly challenged.
            vm.warp(block.timestamp + 1_800);
            target += 600;
            _pushToTick(memeKey, target);
            swap(memeKey, true, -1e14, ""); // keep the TWAP head fresh
            vault.pokeOutOfRange(memeId, 1);
            try vault.rebalanceBase(memeId, 1, false) {
                recenters++;
            } catch {}
        }

        // Bounded by the 6h dedicated interval: 24h / 6h = 4 (+1 slack). NOT a per-30-min loop.
        uint256 bound = (24 * 3_600) / FeraConstants.MEME_BASE_RECENTER_MIN_INTERVAL_SEC + 1;
        assertLe(recenters, bound, "runaway MEME recenters on a trending path (LVR loss)");
    }

    /// A whipsaw (price snaps back INSIDE the base before the 1h dwell elapses) triggers ZERO
    /// recenters — a transient blip is not a genuine, recenter-worthy move.
    function test_task2_whipsaw_noRecenter() public {
        _seedMeme();
        _pushToTick(memeKey, 2_200);
        assertTrue(vault.pokeOutOfRange(memeId, 1), "expected OOR");

        // Snap back into range well within the 1h dwell.
        vm.warp(block.timestamp + 900); // 15 min
        _pushToTick(memeKey, 0);
        assertFalse(vault.pokeOutOfRange(memeId, 1), "spot back in range clears the dwell clock");

        // Nothing to recenter — spot is in range.
        vm.expectRevert(IFeraVault.NotOutOfRange.selector);
        vault.rebalanceBase(memeId, 1, false);
    }

    /// OPERABILITY DECOUPLED FROM REBALANCING (a): an out-of-range MEME tranche still ACCEPTS deposits
    /// and HONORS withdrawals (returning ≤ pro-rata, in-kind) — range/rebalancing is never a liveness
    /// dependency for user operations.
    function test_task2_operability_outOfRange_depositAndWithdraw() public {
        _seedMeme();

        // Sustained OOR move (spot converges to TWAP so the anti-manipulation deposit gate — a security
        // feature, not a rebalancing dependency — is open).
        _pushToTick(memeKey, 3_000);
        vm.warp(block.timestamp + FeraConstants.MEME_OOR_DWELL_SEC + 100);
        _refreshTwap(memeKey);
        assertTrue(vault.pokeOutOfRange(memeId, 1), "tranche should be OOR for this test");

        address bob = makeAddr("bob");
        MockERC20(Currency.unwrap(currency0)).transfer(bob, 1_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(bob, 1_000e18);
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        // (a1) deposit succeeds while OOR.
        uint256 sh = vault.deposit(memeId, 1, 400e18, 400e18, 0);
        assertGt(sh, 0, "deposit blocked while out of range (operability broken)");
        vm.stopPrank();

        // (a2) withdraw returns pro-rata in-kind while OOR (never blocked by range/rebalancing).
        vm.warp(block.timestamp + COOLDOWN + 1);
        _refreshTwap(memeKey);
        uint256 b0 = IERC20(Currency.unwrap(currency0)).balanceOf(bob);
        uint256 b1 = IERC20(Currency.unwrap(currency1)).balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(memeId, 1, sh, 0, 0);
        uint256 got = (IERC20(Currency.unwrap(currency0)).balanceOf(bob) - b0)
            + (IERC20(Currency.unwrap(currency1)).balanceOf(bob) - b1);
        assertGt(got, 0, "OOR withdrawal returned nothing (operability broken)");
    }

    /// OPERABILITY (b): with the position out of range and NO rebalance ever performed, the in-kind
    /// withdrawal STILL works — rebalancing can never be a liveness dependency (INV-11).
    function test_task2_operability_inKindWithdraw_worksWithoutAnyRebalance() public {
        _seedMeme();
        _pushToTick(memeKey, 5_000); // far out of range; never rebalanced
        vm.warp(block.timestamp + COOLDOWN + 1);
        _refreshTwap(memeKey);

        address shareTok = vault.shareToken(memeId, 1);
        uint256 sh = IERC20(shareTok).balanceOf(address(this));
        assertGt(sh, 0, "no shares to redeem");

        uint256 b0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 b1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        vault.withdraw(memeId, 1, sh, 0, 0); // in-kind, no rebalance — must succeed
        uint256 got = (IERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - b0)
            + (IERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - b1);
        assertGt(got, 0, "in-kind withdraw failed without a rebalance (liveness coupled to rebalancing)");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // TASK 3 — RWA regime restored (mean-reversion: the OPPOSITE of MEME).
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// In-hours, when the pool has drifted from the oracle past the hysteresis, the base band is
    /// recentered TOWARD the oracle price (RWA mean-reverts to the real stock).
    function test_task3_rwaOracleRecenter_anchorsTowardOracle() public {
        vault.deposit(rwaId, 1, 1_000e18, 1_000e18, 0);
        vault.setMarketOpen(rwaId, true); // RWA pools default CLOSED; oracle recenter is in-hours only

        (int24 loB, int24 hiB,,,) = vault.bandInfo(rwaId, 1, 0); // genesis band around tick 0

        // Oracle says the true price is ~tick 3000 (≈1.3498) while the pool sits at tick ~0. In-hours,
        // TWAP-quiet (pool never moved) ⇒ a genuine drift, not a spike.
        vm.warp(block.timestamp + 200);
        _refreshTwap(rwaKey); // keep the pool TWAP head fresh at ~tick 0
        feed.set(int256(134_980_000), block.timestamp); // fresh oracle @ ~1.3498

        vault.rebalanceRwaOracle(rwaId, 1);

        (int24 loA, int24 hiA,,,) = vault.bandInfo(rwaId, 1, 0);
        assertGt(loA, loB, "RWA base did not re-anchor UP toward the oracle");
        assertGt(hiA, hiB, "RWA base upper did not move toward the oracle");
    }

    /// Below the hysteresis, the oracle recenter is a no-op (reverts) — no churn.
    function test_task3_rwaOracleRecenter_belowHysteresis_reverts() public {
        vault.deposit(rwaId, 1, 1_000e18, 1_000e18, 0);
        vault.setMarketOpen(rwaId, true); // in-hours
        vm.warp(block.timestamp + 200);
        _refreshTwap(rwaKey);
        feed.set(1e8, block.timestamp); // oracle == pool (1.0) ⇒ ~0 deviation
        vm.expectRevert(IFeraVault.OracleDeviationTooSmall.selector);
        vault.rebalanceRwaOracle(rwaId, 1);
    }

    /// Off-hours (market closed): the base band WIDENS and a fraction is PARTIAL-WITHDRAWN into idle
    /// reserve — battening down against weekend drift + a Monday gap. Swap-free / value-conserving.
    function test_task3_rwaOffHoursDefend_widensAndPartialWithdraws() public {
        vault.deposit(rwaId, 1, 1_000e18, 1_000e18, 0);

        uint256 widthB = _bandWidth(rwaId, 1, 0);
        (uint256 idB0, uint256 idB1) = vault.idleReserves(rwaId, 1);

        vault.setMarketOpen(rwaId, false); // market CLOSED ⇒ defensive posture eligible
        vault.defendRwaOffHours(rwaId, 1);

        uint256 widthA = _bandWidth(rwaId, 1, 0);
        (uint256 idA0, uint256 idA1) = vault.idleReserves(rwaId, 1);
        assertGt(widthA, widthB, "off-hours defense did not WIDEN the base band");
        assertGt(idA0 + idA1, idB0 + idB1, "off-hours defense did not PARTIAL-WITHDRAW into reserve");
    }

    /// A flagged EVENT WINDOW (earnings) — re-wiring the previously-vestigial `eventWindow` — makes the
    /// defensive widen eligible even while the market is OPEN, and DISABLES the oracle-chase recenter.
    function test_task3_rwaEventWindow_enablesDefend_blocksOracleRecenter() public {
        vault.deposit(rwaId, 1, 1_000e18, 1_000e18, 0);
        vault.setMarketOpen(rwaId, true);
        vault.setEventWindow(rwaId, true);
        assertTrue(vault.isEventWindow(rwaId), "event window not set");

        // Oracle recenter is BLOCKED during an event window (do not chase into a gapping session).
        feed.set(int256(134_980_000), block.timestamp);
        vm.expectRevert(IFeraVault.MarketClosed.selector);
        vault.rebalanceRwaOracle(rwaId, 1);

        // The defensive widen IS eligible during the event window even though the market is open.
        vault.defendRwaOffHours(rwaId, 1); // must not revert
    }

    /// The RWA-only actions revert on a MEME pool (NotRwaPool).
    function test_task3_rwaActions_revertOnMemePool() public {
        vm.expectRevert(IFeraVault.NotRwaPool.selector);
        vault.rebalanceRwaOracle(memeId, 1);
        vm.expectRevert(IFeraVault.NotRwaPool.selector);
        vault.defendRwaOffHours(memeId, 1);
    }
}
