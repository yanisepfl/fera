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
import {MockAggregatorV3, MockRebalanceVenue} from "../utils/Mocks.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
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

/// @notice v3 BASE + LIMIT + IDLE strategy tests over a real v4 PoolManager (VAULT_STRATEGY_V3.md
///         — base+limit+idle is the ONLY strategy; the legacy ladder is removed, item 1):
///          - shape: Steady(0)/Active(1) tranches, wide BASE + keeper IDLE + on-demand LIMIT
///          - skimIdle establishes the idle buffer, value-conserving
///          - rebalanceLimit deploys an inventory-skewed (straddling) limit band, swap-free
///          - rebalanceBase guarded-recenter gate matrix + value conservation
///          - MEME frequent-rebalance is interval-bounded (R-15), MEME interval < RWA interval
///          - self-swap bounded: small ok, IL-budget-capped for large; venue slippage bound separate
///          - external venue: allowlist + slippage bound + hostile-venue isolation
///          - withdrawSingle ≤ pro-rata NAV + minOut; in-kind withdraw ALWAYS succeeds (INV-11)
///          - NAV conservation across rebalance/self-swap/single-withdraw (no value created)
///          - v3 NEW: vol-adaptive band sizing (item 2), inventory-driven + oracle-biased limit
///            skew (item 3), IL-capped staged/partial base recenter (item 4, fuzzed), permissionless
///            calling of every rebalance function (item 6), and poke-timer idempotence (item 6 audit)
contract BaseLimitStrategyTest is Deployers {
    using StateLibrary for IPoolManager;

    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;
    MockAggregatorV3 internal feed;
    MockRebalanceVenue internal venue;

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
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), IAnchorStaking(address(0)), address(shareImpl), address(this), address(this)
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

        // v3.3 permissionless creation: team-curation levers must be set before pool creation.
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        vault.approveRwaFeed(address(feed), "test RWA feed");
        memeId = vault.createBaseLimitPool(memeKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME-BL", "mBL");
        rwaId = vault.createBaseLimitPool(rwaKey, FeraTypes.Regime.RWA, address(feed), SQRT_PRICE_1_1, true, "RWA-BL", "rBL");
        vault.setKeeperActive(memeId, true);
        vault.setKeeperActive(rwaId, true);

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);

        // Whitelisted external venue, funded so it can deliver tokenOut.
        venue = new MockRebalanceVenue();
        MockERC20(Currency.unwrap(currency0)).transfer(address(venue), 100_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(address(venue), 100_000e18);
    }

    // ── helpers ────────────────────────────────────────────────────────────────────────────
    function _bal(address who) internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(Currency.unwrap(currency0)).balanceOf(who);
        b1 = IERC20(Currency.unwrap(currency1)).balanceOf(who);
    }

    function _seedMeme() internal {
        vault.deposit(memeId, 0, 1_000e18, 1_000e18, 0);
        vault.deposit(memeId, 1, 1_000e18, 1_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT);
        _refreshTwap(memeKey);
    }

    /// A tiny swap to keep the pool's TWAP head fresh after a warp (REC-9 fail-closed avoidance).
    function _refreshTwap(PoolKey memory key) internal {
        swap(key, true, -1e15, "");
        swap(key, false, -1e15, "");
    }

    /// Push spot to a target tick with a bounded-price swap.
    function _pushToTick(PoolKey memory key, int24 target) internal {
        (, int24 tick,,) = manager.getSlot0(key.toId());
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

    // ═════════════════════════════════════════════════════════════════════════════════════
    // Shape + tier config
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_shape_steadyAndActiveTranches() public view {
        assertEq(vault.trancheCount(memeId), 2, "base+limit pool ships Steady + Active");
        assertTrue(vault.shareToken(memeId, 0) != vault.shareToken(memeId, 1), "distinct shares");

        (uint8 tier0,,, uint16 idle0, bool set0) = vault.tierOf(memeId, 0);
        (uint8 tier1,,, uint16 idle1, bool set1) = vault.tierOf(memeId, 1);
        assertTrue(set0 && set1, "tiers configured");
        assertEq(tier0, FeraConstants.TIER_STEADY);
        assertEq(tier1, FeraConstants.TIER_ACTIVE);
        assertEq(idle0, FeraConstants.STEADY_IDLE_BPS, "steady idle 10%");
        assertEq(idle1, FeraConstants.ACTIVE_IDLE_BPS, "active limit budget 20%");

        // Exactly one BASE band per tranche at init (limit deployed on demand).
        assertEq(vault.bandCount(memeId, 0), 1, "one base band");
        (,,, bool isP, bool isL) = vault.bandInfo(memeId, 0, 0);
        assertTrue(isP && !isL, "band 0 is the BASE");
    }

    function test_configureTier_boundsEnforced() public {
        // idle above the immutable cap reverts (the Gamma lesson — no config un-invests the vault).
        vm.expectRevert(IFeraVault.IdleBpsOutOfBounds.selector);
        vault.configureTier(memeId, 0, FeraConstants.TIER_STEADY, FeraConstants.IDLE_BPS_MAX + 1);
        // unknown tier id reverts.
        vm.expectRevert(IFeraVault.BadTier.selector);
        vault.configureTier(memeId, 0, 7, 500);
        // valid update sticks. v3: limit skew is NOT a configureTier parameter anymore — it is
        // derived deterministically from inventory (§3), so there is nothing to assert here beyond
        // tier/idle.
        vault.configureTier(memeId, 0, FeraConstants.TIER_ACTIVE, 2_000);
        (uint8 tier,,, uint16 idle,) = vault.tierOf(memeId, 0);
        assertEq(tier, FeraConstants.TIER_ACTIVE);
        assertEq(idle, 2_000);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // IDLE — skimIdle establishes the buffer, value-conserving
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_skimIdle_establishesIdle_andRoundTripConserved() public {
        _seedMeme();
        (uint256 r0, uint256 r1) = vault.idleReserves(memeId, 0);
        assertEq(r0 + r1, 0, "no idle before skim");

        vault.skimIdle(memeId, 0);
        (r0, r1) = vault.idleReserves(memeId, 0);
        assertGt(r0 + r1, 0, "skimIdle did not establish an idle reserve");

        // NAV conservation: a deposit -> skim -> full withdraw returns essentially the deposit.
        address alice = makeAddr("alice");
        MockERC20(Currency.unwrap(currency0)).transfer(alice, 2_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(alice, 2_000e18);
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        (uint256 a0, uint256 a1) = _bal(alice);
        uint256 valueBefore = a0 + a1; // swap-free ⇒ price 1:1 ⇒ token0+token1 is a faithful NAV measure
        uint256 sh = vault.deposit(memeId, 0, 1_000e18, 1_000e18, 0);
        vm.stopPrank();

        vault.skimIdle(memeId, 0); // keeper reshapes idle while alice is in

        vm.warp(block.timestamp + COOLDOWN + 1);
        _refreshTwap(memeKey);
        vm.startPrank(alice);
        vault.withdraw(memeId, 0, sh, 0, 0);
        vm.stopPrank();
        (uint256 b0, uint256 b1) = _bal(alice);
        uint256 valueAfter = b0 + b1;
        // Idle reshaping (a keeper action) cannot dilute alice NOR let her extract from others — her
        // redeemable value round-trips within dust (swap-free ⇒ NAV conserved both directions).
        assertGe(valueAfter + 2e15, valueBefore, "skimIdle diluted the depositor beyond dust");
        assertLe(valueAfter, valueBefore + 2e15, "depositor extracted value via idle reshaping");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // LIMIT — rebalanceLimit deploys a skewed straddling limit, swap-free
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_rebalanceLimit_deploysSkewedStraddlingLimit() public {
        _seedMeme();
        vault.skimIdle(memeId, 0); // create the surplus reserve the limit is deployed from

        uint256 before = vault.bandCount(memeId, 0);
        vault.rebalanceLimit(memeId, 0);
        assertEq(vault.bandCount(memeId, 0), before + 1, "limit band not deployed");

        (int24 lo, int24 hi, uint128 liq, bool isP, bool isL) = vault.bandInfo(memeId, 0, before);
        assertTrue(isL && !isP, "deployed band must be the LIMIT (non-principal)");
        assertGt(liq, 0, "limit band empty");
        (, int24 tick,,) = manager.getSlot0(memeId);
        // Skewed but STRADDLES spot (not strictly single-sided): spot inside [lo, hi).
        assertTrue(lo <= tick && tick < hi, "limit must straddle spot");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // BASE — guarded recenter gate matrix + value conservation
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_rebalanceBase_gateMatrix_and_recenter() public {
        _seedMeme();

        // Gate 1 — in range ⇒ NotOutOfRange.
        vm.expectRevert(IFeraVault.NotOutOfRange.selector);
        vault.rebalanceBase(memeId, 1, false); // Active (narrow ±30%) base — easy to push OOR

        // Push spot to tick +2200 — out of the Active base's calm-scaled range (v3 vol-adaptive
        // sizing, §2: a fresh pool's EWMA≈0 ⇒ the calm-floor 0.5× multiplier, so Active's genesis
        // half-width is ~1312 ticks, not the raw ±30%≈2624 tier magnitude) while staying INSIDE
        // Steady's calm-scaled range (~3466 ticks) so Steady's own liquidity stays put (avoids a
        // thin-liquidity cascade past the vault's only depth).
        _pushToTick(memeKey, 2_200);
        assertTrue(vault.pokeOutOfRange(memeId, 1), "expected Active base OOR");
        uint64 since = vault.outOfRangeSince(memeId, 1);
        assertGt(since, 0, "OOR clock not armed");

        // Gate 2 — OOR not yet persistent (< MEME dwell) ⇒ OorNotPersistent.
        vm.expectRevert(IFeraVault.OorNotPersistent.selector);
        vault.rebalanceBase(memeId, 1, false);

        // Sustain the OOR past the FULL TWAP window (not just the dwell — v3 decouples the two, and
        // waiting past the whole averaging window guarantees a clean, fully-post-move TWAP read; a
        // wait of merely dwell+margin can still average in pre-move history), then refresh the TWAP
        // head at the new level so it reads OOR (TWAP-confirmed). Spot stays at ~tick 2200 (a warp
        // never moves price; the tiny refresh swap keeps the head at the sustained level).
        // v3-hardening (§5.1): the MEME dwell is now 1h (> the 30-min TWAP window), so sustain past
        // the DWELL — which also clears the full averaging window for a clean post-move TWAP read.
        vm.warp(block.timestamp + FeraConstants.MEME_OOR_DWELL_SEC + 100);
        swap(memeKey, true, -1e15, ""); // refresh the TWAP head (age → 0), price stays out of range
        assertTrue(vault.pokeOutOfRange(memeId, 1), "price should still be OOR");

        // All gates now hold ⇒ guarded recenter succeeds (value conserved, Gate 5). After a fully
        // one-sided OOR move the closed base is single-token; with selfSwap=false a SYMMETRIC base
        // cannot be re-minted from one token, so its ticks re-anchor at the new spot and the surplus
        // value is conserved into the idle reserve (redeployed next as a limit — the base+limit cycle).
        vault.rebalanceBase(memeId, 1, false);

        assertEq(vault.outOfRangeSince(memeId, 1), 0, "OOR clock not cleared");
        (, int24 tick,,) = manager.getSlot0(memeId);
        (int24 lo, int24 hi,, bool isP,) = vault.bandInfo(memeId, 1, 0);
        assertTrue(isP, "base stayed principal");
        assertTrue(lo <= tick && tick < hi, "base did not re-anchor to straddle the new spot");
        (uint256 rr0, uint256 rr1) = vault.idleReserves(memeId, 1);
        assertGt(rr0 + rr1, 0, "recenter did not conserve the turned-over value into reserve");

        // Base re-anchored ⇒ spot back in range ⇒ next base recenter attempt fails Gate 1 again.
        assertFalse(vault.pokeOutOfRange(memeId, 1), "base still OOR after re-anchor");
        vm.expectRevert(IFeraVault.NotOutOfRange.selector);
        vault.rebalanceBase(memeId, 1, false);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // R-15 — rebalance frequency is interval-bounded; MEME shorter than RWA
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_rebalance_intervalBounded_noGriefing() public {
        // Constant relationship: MEME goes OOR often ⇒ shorter (but non-zero) interval than RWA.
        assertGt(FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC, 0, "MEME interval must be non-zero");
        assertLt(
            FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC,
            FeraConstants.RWA_MIN_REBALANCE_INTERVAL_SEC,
            "MEME interval must be shorter than RWA"
        );

        _seedMeme();
        vault.skimIdle(memeId, 0);
        vault.rebalanceLimit(memeId, 0);

        // Immediate second rebalance reverts — bounded frequency (no tick-boundary griefing).
        vm.expectRevert(IFeraVault.RebalanceTooSoon.selector);
        vault.rebalanceLimit(memeId, 0);

        // Even after the (shorter) MEME interval it works again (bounded, not blocked forever).
        vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
        _refreshTwap(memeKey);
        vault.rebalanceLimit(memeId, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // SELF-SWAP — bounded against the own pool; large impact reverts past the slippage bound
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_selfSwap_small_succeeds() public {
        _seedMeme();
        vault.skimIdle(memeId, 0);
        (uint256 r0,) = vault.idleReserves(memeId, 0);
        // A tiny self-swap (negligible fee + impact < 1% bound) succeeds.
        uint256 out = vault.selfSwap(memeId, 0, true, r0 / 100);
        assertGt(out, 0, "self-swap produced nothing");
    }

    function test_selfSwap_largeImpact_revertsPastIlBudget() public {
        _seedMeme();
        // Shrink the base + grow the reserve so a full-reserve self-swap is a large fraction of NAV.
        vault.configureTier(memeId, 0, FeraConstants.TIER_STEADY, FeraConstants.IDLE_BPS_MAX);
        for (uint256 i; i < 6; ++i) {
            vault.skimIdle(memeId, 0);
        }
        (uint256 r0,) = vault.idleReserves(memeId, 0);
        assertGt(r0, 0, "no reserve to swap");
        // Swapping the whole (now-large, multi-% of NAV) reserve in ONE call exceeds the v3
        // per-call IL-notional budget (MAX_IL_BPS_PER_RECENTER of tranche NAV) — a DIFFERENT bound
        // from the TWAP-execution-slippage one (contracts/VAULT_STRATEGY_V3.md §4).
        vm.expectRevert(IFeraVault.IlBudgetExceeded.selector);
        vault.selfSwap(memeId, 0, true, r0);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // EXTERNAL VENUE — allowlist + same slippage bound + hostile-venue isolation
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_venue_notAllowed_reverts() public {
        _seedMeme();
        vault.skimIdle(memeId, 0);
        (uint256 r0,) = vault.idleReserves(memeId, 0);
        vm.expectRevert(IFeraVault.VenueNotAllowed.selector);
        vault.rebalanceViaVenue(memeId, 0, address(venue), true, r0 / 10);
    }

    function test_venue_okAtFairRate_revertsBelowSlippageBound() public {
        _seedMeme();
        vault.skimIdle(memeId, 0);
        vault.setVenueAllowed(address(venue), true);
        (uint256 r0,) = vault.idleReserves(memeId, 0);
        uint256 amt = r0 / 10;

        // Fair 1:1 rate (spot ~1:1) clears the (1 − 1%) TWAP-implied bound.
        uint256 out = vault.rebalanceViaVenue(memeId, 0, address(venue), true, amt);
        assertApproxEqRel(out, amt, 0.01e18, "fair venue output");

        // A venue that under-delivers past the bound ⇒ RebalanceSlippage (vault's own post-check).
        vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
        _refreshTwap(memeKey);
        venue.setRate(9_800); // 2% haircut > 1% bound
        (uint256 r0b,) = vault.idleReserves(memeId, 0);
        vm.expectRevert(IFeraVault.RebalanceSlippage.selector);
        vault.rebalanceViaVenue(memeId, 0, address(venue), true, r0b / 10);
    }

    function test_venue_hostileRevert_isIsolated_withdrawStillWorks() public {
        _seedMeme();
        vault.skimIdle(memeId, 0);
        vault.setVenueAllowed(address(venue), true);
        venue.setReverting(true); // venue is down / hostile
        (uint256 r0,) = vault.idleReserves(memeId, 0);
        vm.expectRevert(bytes("venue down"));
        vault.rebalanceViaVenue(memeId, 0, address(venue), true, r0 / 10);

        // The bounded call is fully isolated: an ordinary in-kind withdraw still succeeds (INV-11).
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 sh = IERC20(vault.shareToken(memeId, 0)).balanceOf(address(this));
        (uint256 out0, uint256 out1) = vault.withdraw(memeId, 0, sh, 0, 0);
        assertGt(out0 + out1, 0, "in-kind withdraw must always work");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // SINGLE-COIN withdraw ≤ pro-rata NAV + minOut; IN-KIND fallback ALWAYS works
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_withdrawSingle_neverMoreThanProRata_andMinOut() public {
        _seedMeme();
        uint256 sh = IERC20(vault.shareToken(memeId, 0)).balanceOf(address(this));

        // Redeem a small slice so the internal swap fits the pool depth (the user's minOut is the
        // guard here, not the keeper TWAP bound). sh/20 of a (1000e18 + 1000e18) balanced position
        // ⇒ pro-rata NAV ≈ 100e18 valued in token0 at the ~1:1 spot.
        uint256 slice = sh / 20;

        // Impossible minOut ⇒ SingleOutTooLow (and the user can still exit in-kind — see below).
        vm.expectRevert(IFeraVault.SingleOutTooLow.selector);
        vault.withdrawSingle(memeId, 0, slice, Currency.unwrap(currency0), type(uint256).max);

        // Reasonable single-coin redemption succeeds and returns NO MORE than pro-rata NAV.
        (uint256 b0,) = _bal(address(this));
        uint256 out = vault.withdrawSingle(memeId, 0, slice, Currency.unwrap(currency0), 0);
        (uint256 a0,) = _bal(address(this));
        assertEq(a0 - b0, out, "returned token0 mismatch");
        // Single-coin swap only loses fee/slippage ⇒ out ≤ the pro-rata NAV (~100e18). Never more.
        assertLe(out, 100e18 + 1e15, "withdrawSingle returned MORE than pro-rata NAV");
        assertGt(out, 0, "single-coin redemption produced nothing");
    }

    function test_inKindFallback_alwaysAvailable() public {
        _seedMeme();
        uint256 sh = IERC20(vault.shareToken(memeId, 0)).balanceOf(address(this));

        // withdrawSingle with an unreachable minOut reverts...
        vm.expectRevert(IFeraVault.SingleOutTooLow.selector);
        vault.withdrawSingle(memeId, 0, sh, Currency.unwrap(currency1), type(uint256).max);

        // ...but the plain in-kind withdraw is NEVER blockable (INV-11) — the true fallback.
        (uint256 out0, uint256 out1) = vault.withdraw(memeId, 0, sh, 0, 0);
        assertGt(out0, 0, "in-kind token0 missing");
        assertGt(out1, 0, "in-kind token1 missing");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // NAV CONSERVATION across rebalance / self-swap / single-withdraw (no value created)
    // ═════════════════════════════════════════════════════════════════════════════════════

    /// A scripted sequence exercising every value-moving path; the system NEVER creates value:
    /// total value withdrawn ≤ total value deposited (+ dust). Keeper actions are each bounded.
    function test_navConservation_acrossRebalanceSelfSwapSingleWithdraw() public {
        address ref = makeAddr("refHolder");
        MockERC20(Currency.unwrap(currency0)).transfer(ref, 10_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(ref, 10_000e18);
        vm.startPrank(ref);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();

        (uint256 r0i, uint256 r1i) = _bal(ref);
        vm.prank(ref);
        uint256 sh = vault.deposit(memeId, 0, 2_000e18, 2_000e18, 0);
        (uint256 r0a, uint256 r1a) = _bal(ref);
        uint256 valueIn = (r0i - r0a) + (r1i - r1a);

        // Keeper runs the full rebalance cycle (each action on-chain-bounded).
        vault.skimIdle(memeId, 0);
        (uint256 res0,) = vault.idleReserves(memeId, 0);
        if (res0 > 0) vault.selfSwap(memeId, 0, true, res0 / 50); // small bounded self-swap against own pool
        vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
        _refreshTwap(memeKey);
        vault.rebalanceLimit(memeId, 0); // swap-free skewed limit redeploy

        // ref exits: a small single-coin slice + the in-kind rest (both never-blockable, INV-11).
        vm.warp(block.timestamp + COOLDOWN + 1);
        _refreshTwap(memeKey);
        (uint256 s0, uint256 s1) = _bal(ref);
        vm.startPrank(ref);
        vault.withdrawSingle(memeId, 0, sh / 20, Currency.unwrap(currency0), 0);
        vault.withdraw(memeId, 0, IERC20(vault.shareToken(memeId, 0)).balanceOf(ref), 0, 0);
        vm.stopPrank();
        (uint256 e0, uint256 e1) = _bal(ref);
        uint256 valueOut = (e0 - s0) + (e1 - s1);

        // No value created from nothing: out ≤ in (+ dust). Swaps/fees only ever reduce value.
        assertLe(valueOut, valueIn + 1e15, "system created value (NAV conservation violated)");
        // And the holder is not grossly diluted by the bounded keeper actions.
        assertGe(valueOut, (valueIn * 9_700) / 10_000, "holder diluted beyond bounded slippage");
    }

    /// Swap-free fuzz: idle reshaping + limit redeploys + a foreign actor cannot dilute or enrich a
    /// reference holder (token0+token1 conserved with no swaps ⇒ NAV conserved both directions).
    function testFuzz_baseLimit_navConserved_swapFree(uint256[6] calldata seeds) public {
        address ref = makeAddr("ref2");
        address fon = makeAddr("foreign");
        _fund(ref);
        _fund(fon);

        (uint256 ri0, uint256 ri1) = _bal(ref);
        vm.prank(ref);
        uint256 sh = vault.deposit(memeId, 1, 1_500e18, 1_500e18, 0);
        (uint256 ra0, uint256 ra1) = _bal(ref);
        uint256 valueIn = (ri0 - ra0) + (ri1 - ra1);

        uint256 fIn;
        uint256 fOut;
        for (uint256 i; i < seeds.length; ++i) {
            uint256 op = seeds[i] % 4;
            if (op == 0) {
                (uint256 fb0, uint256 fb1) = _bal(fon);
                vm.prank(fon);
                try vault.deposit(memeId, 1, bound(seeds[i] >> 8, 1e18, 2_000e18), bound(seeds[i] >> 8, 1e18, 2_000e18), 0) {
                    (uint256 fa0, uint256 fa1) = _bal(fon);
                    fIn += (fb0 - fa0) + (fb1 - fa1);
                } catch {}
            } else if (op == 1) {
                try vault.skimIdle(memeId, 1) {} catch {}
            } else if (op == 2) {
                vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
                try vault.rebalanceLimit(memeId, 1) {} catch {}
            } else {
                vm.warp(block.timestamp + COOLDOWN + 1);
                uint256 fb = IERC20(vault.shareToken(memeId, 1)).balanceOf(fon);
                if (fb != 0) {
                    (uint256 fbb0, uint256 fbb1) = _bal(fon);
                    vm.prank(fon);
                    try vault.withdraw(memeId, 1, fb, 0, 0) {
                        (uint256 faa0, uint256 faa1) = _bal(fon);
                        fOut += (faa0 - fbb0) + (faa1 - fbb1);
                    } catch {}
                }
            }
        }

        vm.warp(block.timestamp + COOLDOWN + 1);
        (uint256 rs0, uint256 rs1) = _bal(ref);
        vm.prank(ref);
        vault.withdraw(memeId, 1, sh, 0, 0);
        (uint256 re0, uint256 re1) = _bal(ref);
        uint256 valueOut = (re0 - rs0) + (re1 - rs1);

        // Swap-free ⇒ NAV conserved: ref neither diluted (99.9%) nor enriched at foreign's expense.
        assertGe(valueOut, (valueIn * 999) / 1_000, "ref diluted by idle/limit reshaping or foreign churn");
        assertLe(valueOut, valueIn + 1e12, "ref extracted value from foreign holders");
        assertLe(fOut, fIn + 1e12, "foreign created value from nothing");
    }

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(currency0)).transfer(who, 20_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(who, 20_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev token1-terms value of tranche `t` (bands + reserve + pending) at current spot — a proxy
    ///      for the internal `_trancheValue`, computed purely from public views (mirrors the same
    ///      helper in `BaseLimitReaudit_PoC.t.sol`).
    function _trancheValueProxy(PoolId pid, uint8 t) internal view returns (uint256 v) {
        (uint256 r0, uint256 r1) = vault.idleReserves(pid, t);
        (uint256 p0, uint256 p1) = vault.pendingFees(pid, t);
        uint256 a0 = r0 + p0;
        uint256 a1 = r1 + p1;
        uint256 n = vault.bandCount(pid, t);
        (uint160 sp,,,) = manager.getSlot0(pid);
        for (uint256 i; i < n; ++i) {
            (int24 lo, int24 hi, uint128 liq,,) = vault.bandInfo(pid, t, i);
            if (liq == 0) continue;
            (uint256 x0, uint256 x1) = _amtsFor(sp, lo, hi, liq);
            a0 += x0;
            a1 += x1;
        }
        uint256 priceX96 = FullMath.mulDiv(uint256(sp), uint256(sp), 1 << 96);
        v = FullMath.mulDiv(a0, priceX96, 1 << 96) + a1;
    }

    function _amtsFor(uint160 sp, int24 lo, int24 hi, uint128 liq) internal pure returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lo);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(hi);
        if (sp <= sqrtA) {
            amount0 = FullMath.mulDiv(uint256(liq) << 96, sqrtB - sqrtA, uint256(sqrtB) * sqrtA);
        } else if (sp >= sqrtB) {
            amount1 = FullMath.mulDiv(liq, sqrtB - sqrtA, 1 << 96);
        } else {
            amount0 = FullMath.mulDiv(uint256(liq) << 96, sqrtB - sp, uint256(sqrtB) * sp);
            amount1 = FullMath.mulDiv(liq, sp - sqrtA, 1 << 96);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // v3 §2 — VOL-ADAPTIVE SIZING: a volatile pool gets a WIDER band than a calm one, same tier.
    // ═════════════════════════════════════════════════════════════════════════════════════

    /// Pump the MEME EWMA vol via a burst of large same-block-ish tick swings (never leaving the
    /// deep Steady base out of range), then confirm the NEXT limit deploy is wider than the
    /// FIRST (calm, EWMA≈0-at-genesis) deploy for the SAME tier.
    function test_volAdaptiveSizing_volatilePoolGetsWiderBand() public {
        _seedMeme();
        vault.skimIdle(memeId, 0);
        vault.rebalanceLimit(memeId, 0); // deploy #1 at genesis-calm EWMA (≈0 ⇒ floor multiplier)
        (int24 loCalm, int24 hiCalm,,, bool isLCalm) = vault.bandInfo(memeId, 0, vault.bandCount(memeId, 0) - 1);
        assertTrue(isLCalm, "expected the limit band");
        uint256 widthCalm = uint256(uint24(hiCalm - loCalm));

        // Pump vol with a burst of big alternating swings, ending back near the original tick so
        // spot/TWAP stay within the rebalanceLimit TWAP-sanity bound (±5%).
        for (uint256 i; i < 8; ++i) {
            _pushToTick(memeKey, i % 2 == 0 ? int24(1_800) : int24(-1_800));
        }
        _pushToTick(memeKey, 0);

        vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
        _refreshTwap(memeKey);
        vault.skimIdle(memeId, 0); // fresh surplus reserve to redeploy
        vault.rebalanceLimit(memeId, 0); // deploy #2 at the now-pumped EWMA

        (int24 loVol, int24 hiVol,,, bool isLVol) = vault.bandInfo(memeId, 0, vault.bandCount(memeId, 0) - 1);
        assertTrue(isLVol, "expected the limit band");
        uint256 widthVol = uint256(uint24(hiVol - loVol));

        assertGt(widthVol, widthCalm, "volatile pool did not get a wider band than the calm one (same tier)");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // v3 §3 — INVENTORY-DRIVEN LIMIT SKEW: direction matches actual surplus; RWA biases toward oracle
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_inventorySkew_matchesActualSurplus() public {
        _seedMeme();
        // Push spot so the base band's underlying composition skews toward one token, then skim —
        // the skimmed reserve inherits that skew.
        _pushToTick(memeKey, 2_000);
        _refreshTwap(memeKey);
        vault.skimIdle(memeId, 0);
        (uint256 r0, uint256 r1) = vault.idleReserves(memeId, 0);
        (uint160 sp, int24 tick,,) = manager.getSlot0(memeId);
        uint256 priceX96 = FullMath.mulDiv(uint256(sp), uint256(sp), 1 << 96);
        uint256 val0 = FullMath.mulDiv(r0, priceX96, 1 << 96);
        bool surplus0 = val0 >= r1;

        vault.rebalanceLimit(memeId, 0);
        (int24 lo, int24 hi,,, bool isL) = vault.bandInfo(memeId, 0, vault.bandCount(memeId, 0) - 1);
        assertTrue(isL, "expected the limit band");
        assertTrue(lo <= tick && tick < hi, "limit must straddle spot");

        // surplus0 ⇒ the band leans further ABOVE spot than below (upper reach > lower reach);
        // surplus1 ⇒ the opposite. This is the direct, deterministic consequence of the surplus
        // side driving which side of the straddle gets the bulk of the width.
        uint256 upperReach = uint256(uint24(hi - tick));
        uint256 lowerReach = uint256(uint24(tick - lo));
        if (surplus0) {
            assertGt(upperReach, lowerReach, "surplus0 must lean the limit ABOVE spot");
        } else {
            assertGt(lowerReach, upperReach, "surplus1 must lean the limit BELOW spot");
        }
    }

    /// RWA: with a fixed (small) inventory imbalance, an oracle print that AGREES with the
    /// surplus-implied direction leans the skew HARDER; one that DISAGREES leans it SOFTER — both
    /// relative to a neutral (oracle == spot) baseline. The oracle never flips the deployed side.
    function test_inventorySkew_rwaBiasesTowardOracle() public {
        vault.deposit(rwaId, 0, 1_000e18, 1_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT);
        _refreshTwap(rwaKey);
        feed.set(1e8, block.timestamp);

        // A modest push so the reserve is imbalanced but not maximally so (leaves headroom for the
        // oracle bias to move the skew up or down from the neutral baseline).
        _pushToTick(rwaKey, 300);
        _refreshTwap(rwaKey);
        feed.set(1e8, block.timestamp); // keep the oracle fresh (staleness bound) at the pre-bias level
        vault.skimIdle(rwaId, 0);
        (uint256 r0, uint256 r1) = vault.idleReserves(rwaId, 0);
        (uint160 sp0,,,) = manager.getSlot0(rwaId);
        uint256 priceX96_0 = FullMath.mulDiv(uint256(sp0), uint256(sp0), 1 << 96);
        bool surplus0 = FullMath.mulDiv(r0, priceX96_0, 1 << 96) >= r1;

        (,, int24 tierLimitHalf,,) = vault.tierOf(rwaId, 0);

        uint256 snap = vm.snapshotState();

        // Case A: oracle == spot (neutral).
        _syncOracleToSpot(rwaId);
        vault.rebalanceLimit(rwaId, 0);
        uint256 skewNeutral = _measureSkewBps(rwaId, 0, surplus0, tierLimitHalf);

        vm.revertToState(snap);

        // Case B: oracle biased to AGREE with the chosen (surplus) side.
        _biasOracle(rwaId, surplus0, true, 800);
        vault.rebalanceLimit(rwaId, 0);
        uint256 skewAgree = _measureSkewBps(rwaId, 0, surplus0, tierLimitHalf);

        vm.revertToState(snap);

        // Case C: oracle biased to DISAGREE with the chosen side.
        _biasOracle(rwaId, surplus0, false, 800);
        vault.rebalanceLimit(rwaId, 0);
        uint256 skewDisagree = _measureSkewBps(rwaId, 0, surplus0, tierLimitHalf);

        assertGt(skewAgree, skewNeutral, "an agreeing oracle should lean the skew HARDER");
        assertLt(skewDisagree, skewNeutral, "a disagreeing oracle should lean the skew SOFTER");
    }

    function _syncOracleToSpot(PoolId pid) internal {
        (uint160 sp,,,) = manager.getSlot0(pid);
        uint256 priceX96 = FullMath.mulDiv(uint256(sp), uint256(sp), 1 << 96);
        feed.set(int256(FullMath.mulDiv(priceX96, 1e8, 1 << 96)), block.timestamp);
    }

    /// Set the oracle `devBps` away from spot, signed so it AGREES or DISAGREES with `surplus0`'s
    /// implied lean (surplus0 ⇒ "up" is agreement; !surplus0 ⇒ "down" is agreement).
    function _biasOracle(PoolId pid, bool surplus0, bool agree, uint256 devBps) internal {
        (uint160 sp,,,) = manager.getSlot0(pid);
        uint256 priceX96 = FullMath.mulDiv(uint256(sp), uint256(sp), 1 << 96);
        uint256 spot1e8 = FullMath.mulDiv(priceX96, 1e8, 1 << 96);
        bool up = surplus0 == agree; // surplus0&&agree ⇒ up; !surplus0&&agree ⇒ down; etc.
        uint256 moved = up ? spot1e8 + (spot1e8 * devBps) / FeraConstants.BPS : spot1e8 - (spot1e8 * devBps) / FeraConstants.BPS;
        feed.set(int256(moved), block.timestamp);
    }

    /// Recover the approximate skewBps used to place the last limit band, given the FIXED (RWA has
    /// no vol-adaptive scaling) tier half-width.
    function _measureSkewBps(PoolId pid, uint8 t, bool surplus0, int24 halfW) internal view returns (uint256) {
        (int24 lo, int24 hi,,, bool isL) = vault.bandInfo(pid, t, vault.bandCount(pid, t) - 1);
        assertTrue(isL, "expected the limit band");
        (, int24 tick,,) = manager.getSlot0(pid);
        int24 inner = surplus0 ? (tick - lo) : (hi - tick);
        uint256 innerU = uint256(uint24(inner));
        uint256 halfWU = uint256(uint24(halfW));
        if (innerU >= halfWU) return FeraConstants.LIMIT_SKEW_MIN_BPS;
        return FeraConstants.BPS - (innerU * FeraConstants.BPS) / halfWU;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // v3 §4 — IL-CAPPED STAGED/PARTIAL RECENTER: fuzz across large synthetic price gaps
    // ═════════════════════════════════════════════════════════════════════════════════════

    /// No single `rebalanceBase` call may realize more IL than `MAX_IL_BPS_PER_RECENTER` of the
    /// tranche's pre-action NAV — fuzzed across randomized large price gaps (both directions) with
    /// `useSelfSwap` on or off. Provable: a swap's loss can never exceed its own notional, and the
    /// notional is capped to the budget (contracts/VAULT_STRATEGY_V3.md §4).
    function testFuzz_rebalanceBase_ilCapBounded_acrossPriceGaps(uint256 seed, bool selfSwapOn) public {
        _seedMeme();

        // Deep external LP so large synthetic pushes succeed regardless of the vault's own
        // (vol-adaptive, possibly-widened) band coverage.
        (uint160 sp0,,,) = manager.getSlot0(memeId);
        int24 spacing = 60;
        int24 lo = -24_000;
        int24 hi = 24_000;
        uint128 extL = LiquidityAmounts.getLiquidityForAmounts(
            sp0, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), 5_000_000e18, 5_000_000e18
        );
        modifyLiquidityRouter.modifyLiquidity(
            memeKey, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(extL)), salt: bytes32("ext")}), ""
        );
        spacing;

        int24 gap = int24(int256(bound(seed, 5_000, 20_000)));
        bool up = (seed & 1) == 0;
        int24 target = up ? gap : -gap;

        _pushToTick(memeKey, target);
        // Only proceed if this gap actually pushed the Active tranche out of range (it always
        // should, given the magnitude, but guard defensively rather than assume).
        if (!vault.pokeOutOfRange(memeId, 1)) return;

        // Sustain past the FULL TWAP window (not just the dwell) so the TWAP-confirmation gate
        // reads a clean post-gap average, then confirm still OOR.
        vm.warp(block.timestamp + FeraConstants.MEME_OOR_DWELL_SEC + 100); // v3-hardening: 1h dwell
        swap(memeKey, !up, -1e15, ""); // refresh the TWAP head at the sustained level
        if (!vault.pokeOutOfRange(memeId, 1)) return;

        uint256 vBefore = _trancheValueProxy(memeId, 1);
        uint256 ilBudget = (vBefore * FeraConstants.MAX_IL_BPS_PER_RECENTER) / FeraConstants.BPS;

        try vault.rebalanceBase(memeId, 1, selfSwapOn) {
            uint256 vAfter = _trancheValueProxy(memeId, 1);
            if (vBefore > vAfter) {
                assertLe(
                    vBefore - vAfter, ilBudget + 1e15, "single recenter call exceeded the MAX_IL_BPS_PER_RECENTER budget"
                );
            }
        } catch {
            // A gate (e.g. Gate 5 swap-slippage, a DIFFERENT bound) may reject the call entirely —
            // that is a stricter outcome than the IL cap and never a violation of it.
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // v3.4 KEEPER-ONLY STRATEGY (founder decision): EVERY position-moving action — swap-free or
    // swapping — is keeper-gated. Even a bounded swap-free rebalance leaves an adversary the choice
    // of WHEN it fires (cf. the F1 clock-starvation grief this codebase already patched once); zero
    // grief surface beats bounded grief surface. Only the idempotent, nothing-moving pokeOutOfRange
    // stays permissionless. All on-chain bounds (interval, dwell, TWAP) still bind the keeper.
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_allStrategyActionsKeeperOnly_pokeStaysPermissionless() public {
        address rando = makeAddr("totally-random-adversary");
        _seedMeme();
        vault.skimIdle(memeId, 0);

        // Every strategy entrypoint rejects a random caller with OnlyKeeper (the gate precedes all
        // state reads/writes, so nothing is stamped or moved by the attempt).
        (uint256 r0,) = vault.idleReserves(memeId, 0);
        vm.startPrank(rando);
        vm.expectRevert(IFeraVault.OnlyKeeper.selector);
        vault.rebalanceLimit(memeId, 0);
        vm.expectRevert(IFeraVault.OnlyKeeper.selector);
        vault.rebalanceBase(memeId, 0, false);
        vm.expectRevert(IFeraVault.OnlyKeeper.selector);
        vault.selfSwap(memeId, 0, true, r0 / 50);
        vm.expectRevert(IFeraVault.OnlyKeeper.selector);
        vault.rebalanceViaVenue(memeId, 0, address(venue), true, r0 / 10);
        vm.expectRevert(IFeraVault.OnlyKeeper.selector);
        vault.skimIdle(memeId, 0);
        vm.stopPrank();

        // The keeper (this test contract) CAN act — within the UNCHANGED on-chain bounds.
        vault.rebalanceLimit(memeId, 0);
        assertGt(vault.bandCount(memeId, 0), 1, "keeper limit deploy failed");
        vm.expectRevert(IFeraVault.RebalanceTooSoon.selector); // the bounds still bind the keeper
        vault.rebalanceLimit(memeId, 0);

        vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
        _refreshTwap(memeKey);
        (uint256 r0b,) = vault.idleReserves(memeId, 0);
        uint256 out = vault.selfSwap(memeId, 0, true, r0b / 50);
        assertGt(out, 0, "keeper self-swap produced nothing");

        vault.setVenueAllowed(address(venue), true);
        vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
        _refreshTwap(memeKey);
        (uint256 r0c,) = vault.idleReserves(memeId, 0);
        uint256 out2 = vault.rebalanceViaVenue(memeId, 0, address(venue), true, r0c / 10);
        assertGt(out2, 0, "keeper venue rebalance produced nothing");

        // pokeOutOfRange — the ONE permissionless survivor (moves nothing, idempotent): a rando can
        // still arm the OOR observation, and the keeper recenters within dwell + TWAP bounds.
        _pushToTick(memeKey, 2_200); // Active OOR, Steady stays put (v3 vol-adaptive calm-floor sizing)
        vm.prank(rando);
        assertTrue(vault.pokeOutOfRange(memeId, 1), "rando must still be able to poke the OOR state");
        vm.warp(block.timestamp + FeraConstants.MEME_OOR_DWELL_SEC + 100); // v3-hardening: 1h dwell
        swap(memeKey, false, -1e15, "");
        vault.rebalanceBase(memeId, 1, false); // keeper recenter
        assertFalse(vault.pokeOutOfRange(memeId, 1), "base did not re-anchor after the keeper recenter");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // v3 §6 — POKE-TIMER IDEMPOTENCE: repeated pokes cannot manipulate rebalanceBase eligibility
    // ═════════════════════════════════════════════════════════════════════════════════════

    function test_pokeOutOfRange_idempotent_spamCannotDelayEligibility() public {
        _seedMeme();
        _pushToTick(memeKey, 2_200); // tranche 1 (Active) goes OOR; Steady stays put
        assertTrue(vault.pokeOutOfRange(memeId, 1));
        uint64 firstArm = vault.outOfRangeSince(memeId, 1);
        assertGt(firstArm, 0, "OOR clock not armed");

        // Spam-poke immediately (same block) — an attacker gains nothing.
        for (uint256 i; i < 25; ++i) {
            assertTrue(vault.pokeOutOfRange(memeId, 1));
            assertEq(vault.outOfRangeSince(memeId, 1), firstArm, "spam poke moved the dwell clock");
        }

        // One second short of the dwell (measured from the ORIGINAL arm) — still not persistent,
        // even with more spam right up against the deadline.
        vm.warp(uint256(firstArm) + FeraConstants.MEME_OOR_DWELL_SEC - 1);
        for (uint256 i; i < 5; ++i) {
            assertTrue(vault.pokeOutOfRange(memeId, 1));
            assertEq(vault.outOfRangeSince(memeId, 1), firstArm, "late spam moved the dwell clock");
        }
        vm.expectRevert(IFeraVault.OorNotPersistent.selector);
        vault.rebalanceBase(memeId, 1, false);

        // Past the dwell from the ORIGINAL (unmoved) arm, with a clean TWAP confirmation ⇒ eligible.
        vm.warp(uint256(firstArm) + FeraConstants.MEME_OOR_DWELL_SEC + 100); // v3-hardening: 1h dwell
        swap(memeKey, false, -1e15, ""); // refresh TWAP at the sustained level
        vault.rebalanceBase(memeId, 1, false); // must NOT revert OorNotPersistent
        assertFalse(vault.pokeOutOfRange(memeId, 1), "base did not re-anchor");
    }
}
