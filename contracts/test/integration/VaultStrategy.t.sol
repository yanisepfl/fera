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

/// @notice Strategy-layer tests over a real v4 PoolManager:
///          - INV-15 tranche segregation (RWA Core/Anchor) + per-tranche INV-3 (exact 10%)
///          - INV-5″ guarded MEME recenter: every unmet gate reverts; the full path executes
///          - drip kind=5 (new no-swap band) and kind=4 consolidation (D-17)
///          - PT-6 (RWA 4h min recenter interval, now ENFORCED) and PT-7 (q-bounds 0.60/0.80)
contract VaultStrategyTest is Deployers {
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
    uint256 internal constant JIT_WINDOW = 1_800;

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));
        feed = new MockAggregatorV3(8);
        feed.set(1e8, block.timestamp); // 1:1, fresh

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x7777) << 14));
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), address(shareImpl), address(this), address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);

        memeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        rwaKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(hookAddr)
        });

        memeId = vault.createPool(memeKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, "MEME-LP", "mLP");
        rwaId = vault.createPool(rwaKey, FeraTypes.Regime.RWA, address(feed), SQRT_PRICE_1_1, "NVDA-LP", "nLP");

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
    }

    /// Deposit into both pools and step past cooldown + JIT window so checkpoints are clean.
    function _seed() internal {
        vault.deposit(memeId, 0, 100e18, 100e18, 0);
        vault.deposit(rwaId, 0, 50e18, 50e18, 0);
        vault.deposit(rwaId, 1, 50e18, 50e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT_WINDOW);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // INV-15 — tranche segregation + per-tranche INV-3
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_INV15_trancheSharesAreDistinct() public view {
        assertEq(vault.trancheCount(rwaId), 2, "RWA ships Core + Anchor (D-16)");
        assertTrue(vault.shareToken(rwaId, 0) != vault.shareToken(rwaId, 1), "tranche shares must be distinct");
        (,,, bool p0) = vault.bandAt(rwaId, 0, 0);
        (,,, bool p1) = vault.bandAt(rwaId, 1, 0);
        assertTrue(p0 && p1, "principal bands");
    }

    /// Collecting tranche X's fees credits ONLY tranche X; the other tranche's pending and share
    /// supply are untouched. Also: per-tranche INV-3 — perf fee is exactly floor(10%).
    function test_INV15_feeSegregation_and_perTrancheINV3() public {
        _seed();

        // Swap inside the Core band (±100 ticks) — both tranches are in-range and accrue fees.
        swap(rwaKey, true, -1e18, "");
        swap(rwaKey, false, -1e18, "");

        uint256 revBal0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(rev));

        (uint256 fee0, uint256 fee1, uint256 perf0, uint256 perf1) = vault.collectFees(rwaId, 0);
        assertGt(fee0 + fee1, 0, "core collected nothing");

        // INV-3 per tranche: EXACTLY 10% (floor) of collected fees, 0% of principal.
        assertEq(perf0, (fee0 * FeraConstants.PERF_FEE_BPS) / FeraConstants.BPS, "perf0 != 10%");
        assertEq(perf1, (fee1 * FeraConstants.PERF_FEE_BPS) / FeraConstants.BPS, "perf1 != 10%");
        assertEq(
            IERC20(Currency.unwrap(currency0)).balanceOf(address(rev)) - revBal0Before,
            perf0,
            "perf fee not routed to RevenueDistributor"
        );

        // INV-15: Core's collect did not credit Anchor.
        (uint256 aPending0, uint256 aPending1) = vault.pendingFees(rwaId, 1);
        assertEq(aPending0 + aPending1, 0, "cross-tranche fee credit (INV-15 violated)");

        // Core retained exactly the 90%.
        (uint256 cPending0, uint256 cPending1) = vault.pendingFees(rwaId, 0);
        assertEq(cPending0, fee0 - perf0, "core pending != 90% of fee0");
        assertEq(cPending1, fee1 - perf1, "core pending != 90% of fee1");

        // Anchor then collects its OWN accrual — nonzero, independent.
        (uint256 aFee0, uint256 aFee1,,) = vault.collectFees(rwaId, 1);
        assertGt(aFee0 + aFee1, 0, "anchor accrued nothing despite being in-range");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // INV-5″ — guarded MEME recenter: the full condition matrix
    // ═════════════════════════════════════════════════════════════════════════════════════

    /// Push price beyond the mid band so only the tail quotes at spot ⇒ depth breach.
    function _breachDepth() internal {
        // Buy token0 hard: price rises through core (2640) and mid (6960) into tail-only range.
        swap(memeKey, false, -400e18, "");
        assertTrue(vault.pokeDepthBreach(memeId), "expected depth breach after 4x pump");
    }

    function test_INV5pp_gateMatrix_and_execution() public {
        _seed();

        // Gate 1: healthy pool refuses (covered in VaultLifecycle too, kept for the matrix).
        vm.expectRevert(IFeraVault.DepthNotBreached.selector);
        vault.recenterMeme(memeId, bytes32(0));

        _breachDepth();
        uint64 since = vault.depthBreachSince(memeId);
        assertGt(since, 0, "breach clock not armed");

        // Gate 2: breached but NOT yet persistent (< 24h) ⇒ revert.
        vm.warp(since + FeraConstants.MEME_RECENTER_PERSIST_SEC - 1);
        vm.expectRevert(IFeraVault.BreachNotPersistent.selector);
        vault.recenterMeme(memeId, bytes32(0));

        // All gates pass at exactly 24h persistence (interval gate: never recentered before).
        vm.warp(since + FeraConstants.MEME_RECENTER_PERSIST_SEC);
        swap(memeKey, true, -1e15, ""); // REC-9: refresh the TWAP head (a live pool trades) so the
            // deposit/recenter fail-closed staleness bound is not tripped after a long test-only warp
        vault.recenterMeme(memeId, bytes32("justified"));

        // Post-conditions: clock cleared, interval armed, ladder re-anchored at current spot.
        assertEq(vault.depthBreachSince(memeId), 0, "breach clock not cleared");
        (, int24 tick,,) = manager.getSlot0(memeId);
        (int24 lo, int24 hi, uint128 lCore, bool isP) = vault.bandAt(memeId, 0, 0);
        assertTrue(isP, "core stayed principal");
        assertGt(lCore, 0, "core not re-minted");
        assertTrue(lo <= tick && tick < hi, "core band does not straddle spot after recenter");

        // Depth restored ⇒ the very next attempt fails Gate 1 again (and Gate 3 if re-breached).
        assertFalse(vault.pokeDepthBreach(memeId), "depth not restored by recenter");
        vm.expectRevert(IFeraVault.DepthNotBreached.selector);
        vault.recenterMeme(memeId, bytes32(0));
    }

    /// Gate 3 in isolation: a second recenter inside 7d reverts EVEN IF depth re-breaches and
    /// re-persists for 24h. (24h + 24h persistence < 7d interval ⇒ RecenterTooSoon.)
    function test_INV5pp_minInterval7d() public {
        _seed();
        _breachDepth();
        uint64 since = vault.depthBreachSince(memeId);
        vm.warp(since + FeraConstants.MEME_RECENTER_PERSIST_SEC);
        swap(memeKey, true, -1e15, ""); // REC-9: refresh TWAP head (see note above)
        vault.recenterMeme(memeId, bytes32(0));

        // Re-breach immediately (dump the other way, out through the re-centered mid band).
        swap(memeKey, true, -600e18, "");
        assertTrue(vault.pokeDepthBreach(memeId), "dump did not re-breach depth");
        uint64 since2 = vault.depthBreachSince(memeId);

        vm.warp(since2 + FeraConstants.MEME_RECENTER_PERSIST_SEC); // persistent again — but < 7d
        assertTrue(vault.pokeDepthBreach(memeId), "breach did not persist");
        vm.expectRevert(IFeraVault.RecenterTooSoon.selector);
        vault.recenterMeme(memeId, bytes32(0));
    }

    /// Fuzz the wait time: recenterMeme only ever succeeds when BOTH the 24h persistence AND the
    /// still-breached-now condition hold; otherwise it reverts with the matching gate error.
    function testFuzz_INV5pp_persistenceGate(uint256 wait) public {
        _seed();
        _breachDepth();
        uint64 since = vault.depthBreachSince(memeId);
        wait = bound(wait, 0, 3 * uint256(FeraConstants.MEME_RECENTER_PERSIST_SEC));
        vm.warp(since + wait);

        if (wait < FeraConstants.MEME_RECENTER_PERSIST_SEC) {
            vm.expectRevert(IFeraVault.BreachNotPersistent.selector);
            vault.recenterMeme(memeId, bytes32(0));
        } else {
            swap(memeKey, true, -1e15, ""); // REC-9: refresh TWAP head (see note above)
            vault.recenterMeme(memeId, bytes32(0)); // all other gates hold in this scenario
            assertEq(vault.depthBreachSince(memeId), 0);
        }
    }

    /// pokeDepthBreach clears a stale breach if depth recovers (conservative direction: a cleared
    /// clock can only DELAY a recenter, never enable it early).
    function test_INV5pp_breachClockClearsOnRecovery() public {
        _seed();
        _breachDepth();
        assertGt(vault.depthBreachSince(memeId), 0);

        // Arb the price back to ~spot (inside the ladder) ⇒ depth recovers ⇒ clock must clear.
        _swapToTick(0);
        assertFalse(vault.pokeDepthBreach(memeId), "depth should have recovered");
        assertEq(vault.depthBreachSince(memeId), 0, "breach clock must clear on recovery");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // Drip — kind=5 new band, kind=4 consolidation (D-17)
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_drip_deploysNewBand_kind5_thenConsolidates_kind4() public {
        _seed();

        // Generate fee income (sell-side swaps accrue token0 fees).
        swap(memeKey, true, -60e18, "");
        swap(memeKey, false, -30e18, "");

        vm.warp(block.timestamp + FeraConstants.MEME_DRIP_MIN_INTERVAL_SEC);
        uint256 bandsBefore = vault.bandCount(memeId, 0);

        vm.recordLogs();
        vault.drip(memeId, 0);
        assertEq(vault.bandCount(memeId, 0), bandsBefore + 1, "drip did not mint a new band");
        (,, uint128 lDrip, bool isP) = vault.bandAt(memeId, 0, bandsBefore);
        assertGt(lDrip, 0, "drip band empty");
        assertFalse(isP, "drip band must be FEE-class, not principal (D-17)");

        // Interval gate: an immediate second drip reverts.
        vm.expectRevert(IFeraVault.DripTooSoon.selector);
        vault.drip(memeId, 0);

        // Move spot INTO the drip band's neighborhood, accrue more fees, drip again ⇒ the
        // ±10% consolidation path compounds into the existing fee band (kind=4, no new band).
        (int24 dLo, int24 dHi,,) = vault.bandAt(memeId, 0, bandsBefore);
        int24 target = (dLo + dHi) / 2;
        _swapToTick(target);
        swap(memeKey, true, -30e18, "");
        swap(memeKey, false, -15e18, "");

        vm.warp(block.timestamp + FeraConstants.MEME_DRIP_MIN_INTERVAL_SEC);
        uint256 bandsAfterFirst = vault.bandCount(memeId, 0);
        vault.drip(memeId, 0);
        assertEq(vault.bandCount(memeId, 0), bandsAfterFirst, "consolidation must NOT mint a band (D-17)");
    }

    /// Nudge spot near a target tick with a bounded-price swap.
    function _swapToTick(int24 target) internal {
        (, int24 tick,,) = manager.getSlot0(memeId);
        bool up = target > tick;
        swapRouter.swap(
            memeKey,
            SwapParams({
                zeroForOne: !up,
                amountSpecified: -int256(1_000e18),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // RWA — PT-6 min interval (ENFORCED), PT-7 q-bounds, INV-6 legs
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_PT6_rwaMinRecenterInterval_enforced() public {
        _seed();
        vault.setMarketOpen(rwaId, true);
        feed.set(1e8, block.timestamp);

        vault.recenter(rwaId, -180, 180, bytes32(0)); // first recenter: hysteresis vs 0-baseline passes

        // Tick-boundary griefing (PT-6): an immediate second recenter MUST revert.
        feed.set(101e6, block.timestamp); // +1% — past hysteresis
        vm.expectRevert(IFeraVault.RecenterTooSoon.selector);
        vault.recenter(rwaId, -170, 190, bytes32(0));

        // After the frozen 4h interval it works again.
        vm.warp(block.timestamp + FeraConstants.RWA_MIN_RECENTER_INTERVAL_SEC);
        feed.set(101e6, block.timestamp);
        swap(rwaKey, true, -1e15, ""); // REC-9: refresh the TWAP head after the 4h warp (active pool)
        vault.recenter(rwaId, -170, 190, bytes32(0));
    }

    function test_INV6_recenterGates() public {
        _seed();

        // Market closed ⇒ revert.
        vm.expectRevert(IFeraVault.MarketClosed.selector);
        vault.recenter(rwaId, -180, 180, bytes32(0));

        // Open but stale oracle ⇒ revert.
        vault.setMarketOpen(rwaId, true);
        feed.set(1e8, block.timestamp - FeraConstants.ORACLE_STALENESS_MAX - 1);
        vm.expectRevert(IFeraVault.OracleStale.selector);
        vault.recenter(rwaId, -180, 180, bytes32(0));

        // Fresh oracle, but hysteresis unmet (needs a PRIOR recenter to set the baseline).
        feed.set(1e8, block.timestamp);
        vault.recenter(rwaId, -180, 180, bytes32(0)); // baseline set at 1e18
        vm.warp(block.timestamp + FeraConstants.RWA_MIN_RECENTER_INTERVAL_SEC);
        feed.set(100_04e4, block.timestamp); // +0.04% < 50bp hysteresis
        vm.expectRevert(IFeraVault.HysteresisNotMet.selector);
        vault.recenter(rwaId, -180, 180, bytes32(0));

        // Past hysteresis but pool TWAP far from oracle ⇒ revert (spot is 1:1; oracle +4%).
        feed.set(104e6, block.timestamp);
        swap(rwaKey, true, -1e15, ""); // REC-9: refresh TWAP head so the check reaches TWAP-sanity (not stale)
        vm.expectRevert(IFeraVault.TwapOutOfBand.selector);
        vault.recenter(rwaId, -180, 180, bytes32(0));
    }

    function test_PT7_partialWithdraw_qBounds() public {
        _seed();
        feed.set(1e8, block.timestamp); // refresh oracle (the seed warp aged it past staleness)
        // Off-hours action: market closed by default for RWA.
        (,, uint128 lCore,) = vault.bandAt(rwaId, 0, 0);

        // Above q=0.60 ⇒ revert.
        uint128 tooMuch = uint128((uint256(lCore) * 6_100) / 10_000);
        vm.expectRevert(IFeraVault.WithdrawFracExceeded.selector);
        vault.partialWithdraw(rwaId, tooMuch, bytes32(0));

        // ≤ 0.60 ⇒ allowed; liquidity lands in reserves (principal preserved).
        uint128 ok = uint128((uint256(lCore) * 6_000) / 10_000);
        vault.partialWithdraw(rwaId, ok, bytes32(0));
        (,, uint128 lAfter,) = vault.bandAt(rwaId, 0, 0);
        assertEq(uint256(lAfter), uint256(lCore) - ok, "core liquidity accounting");

        // Event session (D-M11): the cap rises to 0.80 of the REMAINING band.
        vault.setEventWindow(rwaId, true);
        uint128 evTooMuch = uint128((uint256(lAfter) * 8_100) / 10_000);
        vm.expectRevert(IFeraVault.WithdrawFracExceeded.selector);
        vault.partialWithdraw(rwaId, evTooMuch, bytes32(0));
        uint128 evOk = uint128((uint256(lAfter) * 8_000) / 10_000);
        vault.partialWithdraw(rwaId, evOk, bytes32(0));

        // In-hours ⇒ blocked entirely.
        vault.setMarketOpen(rwaId, true);
        vm.expectRevert(IFeraVault.MarketOpen.selector);
        vault.partialWithdraw(rwaId, 1, bytes32(0));
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // COV-1 — FeraVault._readOracle negative paths (D-9): zero/negative answer + unset feed.
    // (Stale-timestamp OracleStale is already covered by test_INV6_recenterGates.)
    // ═════════════════════════════════════════════════════════════════════════════════════

    /// Oracle prints a non-positive answer (0 or negative) ⇒ `_readOracle` reverts OracleStale on the
    /// `answer <= 0` leg — the recenter gate refuses to anchor to a garbage price.
    function test_INV6_oracle_zeroAnswer_reverts() public {
        _seed();
        vault.setMarketOpen(rwaId, true);
        feed.set(0, block.timestamp); // fresh timestamp, but answer == 0
        vm.expectRevert(IFeraVault.OracleStale.selector);
        vault.recenter(rwaId, -180, 180, bytes32(0));
    }

    function test_INV6_oracle_negativeAnswer_reverts() public {
        _seed();
        vault.setMarketOpen(rwaId, true);
        feed.set(-5, block.timestamp);
        vm.expectRevert(IFeraVault.OracleStale.selector);
        vault.recenter(rwaId, -180, 180, bytes32(0));
    }

    /// An RWA pool created with NO oracle feed ⇒ `_readOracle` reverts OracleStale on the
    /// `feed == address(0)` leg (a mis-provisioned RWA pool can never recenter blind).
    function test_INV6_oracle_unsetFeed_reverts() public {
        PoolKey memory k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 30,
            hooks: IHooks(address(hook))
        });
        PoolId id = vault.createPool(k, FeraTypes.Regime.RWA, address(0), SQRT_PRICE_1_1, "NOFEED-LP", "nfLP");
        vault.deposit(id, 0, 50e18, 50e18, 0);
        vault.deposit(id, 1, 50e18, 50e18, 0);
        vault.setMarketOpen(id, true); // pass the market-open gate so _readOracle is reached
        vm.expectRevert(IFeraVault.OracleStale.selector);
        vault.recenter(id, -180, 180, bytes32(0));
    }

    function test_rwa_widen_offHoursOnly() public {
        _seed();
        vault.setMarketOpen(rwaId, true);
        vm.expectRevert(IFeraVault.MarketOpen.selector);
        vault.widen(rwaId, -540, 540, bytes32(0));

        vault.setMarketOpen(rwaId, false);
        feed.set(1e8, block.timestamp);
        vault.widen(rwaId, -540, 540, bytes32(0));
        (int24 lo, int24 hi,,) = vault.bandAt(rwaId, 0, 0);
        assertEq(lo, -540);
        assertEq(hi, 540);
    }
}
