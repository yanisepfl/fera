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

/// @notice LENS: PERMISSIONLESS-CALLER SAFETY (VAULT_STRATEGY_V3.md §6 / stage-1 item 6).
///         Two griefing/DoS PoCs on the now-permissionless rebalance surface. Neither steals funds
///         (INV-3/11/15/16 hold; the 1% execution and 3% IL bounds hold regardless of caller) — both
///         are availability/yield-degradation attacks the v3 permissionless-safety writeup does not
///         cover:
///           1. SHARED interval clock — a cheap `rebalanceLimit` (swap-free) resets the SAME
///              `lastRebalanceTs` slot the high-value `rebalanceBase` recenter reads, so an attacker
///              can starve base recentering indefinitely by front-running each interval boundary.
///           2. POKE dwell-clock reset via momentary spot manipulation — the idempotence writeup only
///              proves spam is a no-op WHILE STILL OOR; but `pokeOutOfRange` clears `oorSince` on a
///              raw-SPOT in-range read (no TWAP gate on the CLEAR path), so a same-tx in-range flicker
///              resets the dwell and pushes rebalanceBase eligibility strictly later.
contract PermissionlessRebalancePoC is Deployers {
    using StateLibrary for IPoolManager;

    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;
    MockAggregatorV3 internal feed;

    PoolKey internal memeKey;
    PoolId internal memeId;

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
            manager,
            IFeraHook(hookAddr),
            IRevenueDistributor(address(rev)),
            IAnchorStaking(address(0)),
            address(shareImpl),
            address(this),
            address(this)
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

        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        memeId = vault.createBaseLimitPool(
            memeKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME-BL", "mBL"
        );
        vault.setKeeperActive(memeId, true);

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
    }

    // ── helpers (mirror BaseLimitStrategy.t.sol) ─────────────────────────────────────────────
    function _seedMeme() internal {
        vault.deposit(memeId, 0, 1_000e18, 1_000e18, 0);
        vault.deposit(memeId, 1, 1_000e18, 1_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT);
        _refreshTwap();
    }

    function _refreshTwap() internal {
        swap(memeKey, true, -1e15, "");
        swap(memeKey, false, -1e15, "");
    }

    function _pushToTick(int24 target) internal {
        (, int24 tick,,) = manager.getSlot0(memeId);
        bool up = target > tick;
        swapRouter.swap(
            memeKey,
            SwapParams({
                zeroForOne: !up,
                amountSpecified: -int256(5_000_000e18),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // FINDING 1 — CLOSED (v3-hardening §5.1, closes OD-13): the base recenter now runs on a DEDICATED
    // clock (`lastBaseRecenterTs`), SEPARATE from the general `lastRebalanceTs` the swap-free
    // `rebalanceLimit` stamps. So cheap limit-fill spam can NO LONGER starve the high-value base
    // recenter: with OOR + dwell + TWAP satisfied, the honest recenter goes through EVEN IF an attacker
    // just front-ran a limit-fill. The base recenter is still strictly bounded — by its OWN long
    // interval (MEME_BASE_RECENTER_MIN_INTERVAL_SEC, 6h) — so it fires rarely, never runaway.
    // ══════════════════════════════════════════════════════════════════════════════════════════
    function test_F1_rebalanceLimitSpam_doesNotStarveRebalanceBase() public {
        address attacker = makeAddr("griefer");

        _seedMeme();
        // A genuine, sustained move takes the Active(1) base out of range.
        _pushToTick(2_200);
        assertTrue(vault.pokeOutOfRange(memeId, 1), "expected Active base OOR");
        uint64 armed = vault.outOfRangeSince(memeId, 1);
        assertGt(armed, 0, "OOR clock armed");

        // Let the move mature past the (now 1h) dwell — which also clears the TWAP window — then
        // refresh so the 30-min TWAP confirms.
        vm.warp(uint256(armed) + FeraConstants.MEME_OOR_DWELL_SEC + 100);
        _refreshTwap();

        // v3.4: the attacker can no longer drive `rebalanceLimit` AT ALL (keeper-only) — the grief
        // CHANNEL this test originally documented is now closed at the caller gate, not just bounded.
        vm.prank(attacker);
        vm.expectRevert(IFeraVault.OnlyKeeper.selector);
        vault.rebalanceLimit(memeId, 1);
        // Defense-in-depth (the original F1 fix, KEPT): even the KEEPER's own limit action stamps only
        // the GENERAL `lastRebalanceTs`, NOT the dedicated base-recenter clock — a limit action can
        // never starve the high-value base recenter regardless of who triggers it.
        vault.rebalanceLimit(memeId, 1);

        // FIXED: the honest base recenter is NOT blocked by the limit's clock — its Gate-3 reads only
        // `lastBaseRecenterTs` (still 0 here). It succeeds despite the limit action.
        vault.rebalanceBase(memeId, 1, false);
        assertEq(vault.outOfRangeSince(memeId, 1), 0, "OOR cleared by a SUCCESSFUL recenter (not starved)");
        assertFalse(vault.pokeOutOfRange(memeId, 1), "base re-anchored - bulk capital recentered");

        // And it is still RARE, never runaway: an immediate second recenter reverts on the dedicated
        // 6h clock even after re-arming a fresh OOR + satisfying the dwell again. NB: the recenter
        // re-derived the base at the now-elevated EWMA, so the band is VERY wide (LVR hold-in-range) —
        // push far past it (tick 150k ≫ the ≤~68k widened Active band) to force a fresh OOR.
        _pushToTick(150_000);
        assertTrue(vault.pokeOutOfRange(memeId, 1), "re-OOR after a further push");
        // Satisfy the dwell again; do NOT refresh the TWAP (a refresh swap would nudge spot back into
        // the wide band). Gate 3 (interval) precedes Gate 4 (TWAP), so RebalanceTooSoon fires first.
        vm.warp(block.timestamp + FeraConstants.MEME_OOR_DWELL_SEC + 100); // dwell satisfied again
        vm.expectRevert(IFeraVault.RebalanceTooSoon.selector);
        vault.rebalanceBase(memeId, 1, false); // blocked by the 6h base-recenter interval (Gate 3)
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // FINDING 2 — CLOSED (OPEN_DECISIONS.md#OD-14, independently re-flagged by open-kritt):
    // `pokeOutOfRange`'s CLEAR path used to reset `oorSince` on a raw-SPOT in-range read alone, with
    // NO TWAP gate (asymmetric with rebalanceBase's own TWAP-confirmed Gate 4). A same-block spot
    // round-trip (push in-range, poke, push back OOR) could reset a genuine dwell clock, delaying
    // rebalanceBase eligibility strictly past the FIRST genuine breach. The CLEAR transition is now
    // gated on `VaultMath.twapConfirmsRecovery` — a same-tx flicker cannot move the 30-min TWAP, so
    // it can no longer forge a clear. The ARM side is UNCHANGED by design (see `pokeOutOfRange`'s own
    // NatSpec): `rebalanceBase`'s Gate 4 already independently re-confirms TWAP-OOR at execution
    // time, so a spot-only arm can only start the dwell clock EARLIER, never fire the recenter on an
    // unconfirmed spike — and gating the arm side too would delay detection of GENUINE breaches by
    // however long the TWAP takes to catch up, a real regression to the normal (non-adversarial)
    // "push then poke in the same block" flow this whole test suite (and real keeper bots) use.
    // ══════════════════════════════════════════════════════════════════════════════════════════
    function test_F2_pokeDwellReset_viaMomentarySpot_noLongerDelaysEligibility() public {
        _seedMeme();
        _pushToTick(2_200); // Active(1) base OOR
        assertTrue(vault.pokeOutOfRange(memeId, 1), "expected OOR");
        uint64 firstArm = vault.outOfRangeSince(memeId, 1);
        assertGt(firstArm, 0, "armed at first genuine breach");

        // Advance to ONE SECOND short of dwell expiry — rebalanceBase is about to become eligible.
        vm.warp(uint256(firstArm) + FeraConstants.MEME_OOR_DWELL_SEC - 1);

        // ---- The FORMER attack (bundled atomically; the price round-trip near the band edge is the
        //      only cost). Step A: momentarily move spot back INTO the base band, SAME block — the
        //      30-min TWAP cannot have moved at all, so it still reads OOR.
        _pushToTick(0);
        // Step B: poke while spot is (momentarily) in-range. FIXED: since the TWAP does NOT confirm
        // this "recovery" (same-block push cannot move a 30-min average), `oorSince` is NOT cleared —
        // the poke correctly reports the CURRENT spot reading (not-OOR) without discarding real dwell.
        assertFalse(vault.pokeOutOfRange(memeId, 1), "poke still reports the current (momentary) spot reading");
        assertEq(vault.outOfRangeSince(memeId, 1), firstArm, "dwell clock preserved -- TWAP never confirmed the flicker as a recovery");
        // Step C: spot returns OOR (genuine market pressure / attacker un-does the round trip).
        _pushToTick(2_200);
        assertTrue(vault.pokeOutOfRange(memeId, 1), "still OOR");
        assertEq(vault.outOfRangeSince(memeId, 1), firstArm, "poking OOR again is idempotent -- clock unchanged");

        // Satisfy the dwell (now measured from the UNCHANGED firstArm) and refresh so the 30-min TWAP
        // itself confirms the OOR — the honest recenter succeeds, exactly as if the flicker never
        // happened.
        vm.warp(uint256(firstArm) + FeraConstants.MEME_OOR_DWELL_SEC + 100);
        _refreshTwap();
        vault.rebalanceBase(memeId, 1, false);
        assertEq(vault.outOfRangeSince(memeId, 1), 0, "OOR cleared by a SUCCESSFUL recenter");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // FINDING 3 — CLOSED (founder follow-up to OD-14, 2026-07-24): a spot-only arm that NEVER gets
    // TWAP-confirmed (a flicker whose brief in-range window nobody happened to poke during — poke
    // is permissionless but not guaranteed to run every block) sat armed INDEFINITELY. Its accrued
    // dwell time could then be spent by a LATER, entirely unrelated, genuine breach: the FIRST poke
    // on that new breach would see `oorSince != 0` (still the ancient, never-confirmed value) and
    // leave it untouched, so `rebalanceBase`'s Gate 2 (`block.timestamp - since < dwell`) was
    // ALREADY satisfied on arrival — the new breach never had to accrue its own dwell at all.
    // Fixed: `pokeOutOfRange` now resets `oorSince` to `now` if the existing arm has stood longer
    // than `OOR_ARM_TWAP_DEADLINE_SEC` (1h) with the TWAP STILL not confirming it — so a fresh
    // breach must accrue its OWN dwell, while a genuinely continuous, already-TWAP-confirmed move
    // is untouched (the reset only fires when TWAP does NOT confirm, matching the same "only ever
    // makes the arm effectively conservative" discipline the rest of this function's NatSpec
    // documents).
    // ══════════════════════════════════════════════════════════════════════════════════════════
    function test_F3_staleUnconfirmedArm_noLongerGrantsInstantDwellToLaterBreach() public {
        _seedMeme();

        // Step A: a one-off flicker arms the clock. Same-block push -> TWAP cannot have moved.
        _pushToTick(2_200);
        assertTrue(vault.pokeOutOfRange(memeId, 1), "flicker arms the clock");
        uint64 staleArm = vault.outOfRangeSince(memeId, 1);
        assertGt(staleArm, 0);

        // Step B: spot recovers on its own. Deliberately do NOT poke here — the realistic gap this
        // finding is about: poke is permissionless but nothing guarantees it runs during the exact
        // window spot happens to be back in-range.
        _pushToTick(0);

        // Step C: a long, quiet stretch passes — nobody pokes, TWAP settles fully in-range (the
        // original flicker genuinely never persisted). Past the stale-arm deadline.
        vm.warp(block.timestamp + FeraConstants.OOR_ARM_TWAP_DEADLINE_SEC + 100);
        _refreshTwap();

        // Step D: a brand-new, GENUINE breach starts, and is poked IMMEDIATELY (realistic keeper
        // cadence) — well before its OWN 30-min TWAP window could possibly confirm it yet.
        _pushToTick(2_200);
        assertTrue(vault.pokeOutOfRange(memeId, 1), "new breach arms/re-arms");
        uint64 newArm = vault.outOfRangeSince(memeId, 1);

        // FIXED: the stale, never-confirmed arm was reset — the new breach starts its OWN clock
        // rather than inheriting the ancient timestamp (which would have trivially satisfied Gate 2
        // on arrival, since `block.timestamp - staleArm` already vastly exceeds the dwell).
        assertGt(newArm, staleArm, "stale unconfirmed arm was reset, not reused");
        assertEq(newArm, block.timestamp, "fresh breach armed at NOW, not backdated");

        // Gate 2 (dwell) correctly blocks the fresh breach immediately — it has not had time to
        // accrue dwell of its own yet, unlike the old (bugged) behavior where the ancient
        // `staleArm` would have already satisfied Gate 2 on this very first poke.
        vm.expectRevert(IFeraVault.OorNotPersistent.selector);
        vault.rebalanceBase(memeId, 1, false);

        // And once the FRESH arm's own dwell elapses + its own TWAP confirms, the honest recenter
        // still succeeds exactly as normal — the fix only removes the illegitimate shortcut.
        vm.warp(uint256(newArm) + FeraConstants.MEME_OOR_DWELL_SEC + 100);
        _refreshTwap();
        vault.rebalanceBase(memeId, 1, false);
        assertEq(vault.outOfRangeSince(memeId, 1), 0, "OOR cleared by a SUCCESSFUL recenter");
    }

}
