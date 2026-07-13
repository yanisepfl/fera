// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {FeraHook} from "../../src/FeraHook.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice R-23 (skill-audit MED) regression — the FeraHook TWAP window must not collapse under fast
///         blocks. Pre-fix the ring wrote one observation PER BLOCK, so 24 slots held only ~seconds of
///         real history on a ~100ms-block chain and the "600/1800s" deposit-gate/recenter TWAP was
///         really a ~seconds average. The fix keeps a floating HEAD advanced on every swap (same-block
///         push still excluded) but freezes a new ring slot only once per TWAP_OBS_SPACING_SEC, so
///         CARD·SPACING of REAL time is spanned.
/// @dev    IMPORTANT: this repo builds with `via_ir` + very high optimizer_runs, which CSE-folds
///         repeated `block.timestamp` reads within a single test body (valid on-chain — timestamp is
///         tx-invariant — but it defeats mid-test `vm.warp`). So we track wall-clock in a LOCAL
///         counter and warp to ABSOLUTE timestamps, never `block.timestamp + delta`.
contract TwapWindowPoCTest is Deployers {
    using StateLibrary for IPoolManager;

    FeraHook internal hook;
    PoolKey internal pkey;
    PoolId internal id;

    uint32 internal constant WINDOW = FeraConstants.RWA_TWAP_WINDOW; // 1800s — the widest TWAP window
    uint256 internal constant T0 = 2_000_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x7A17) << 14));
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(this)), hookAddr);
        hook = FeraHook(hookAddr);

        pkey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        id = pkey.toId();
        hook.registerRegime(pkey, FeraTypes.Regime.MEME);
        manager.initialize(pkey, SQRT_PRICE_1_1); // seeds the oracle at tick 0

        vm.warp(T0);
        // Deep, wide liquidity so swaps move the tick by controllable, bounded amounts.
        modifyLiquidityRouter.modifyLiquidity(
            pkey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: int256(50_000e18),
                salt: 0
            }),
            ""
        );
    }

    function _swap(bool zeroForOne, int256 amt) internal {
        swap(pkey, zeroForOne, amt, "");
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }

    /// Cardinality literal in the hook must equal the FeraConstants source of truth, and
    /// (CARD − 1)·SPACING must cover the widest TWAP window so the anchor can reach ≥ window.
    function test_R23_cardinalityConstantsMatch() public pure {
        assertEq(uint256(FeraConstants.TWAP_OBS_CARDINALITY), 24, "cardinality drift");
        assertGe(
            (uint256(FeraConstants.TWAP_OBS_CARDINALITY) - 1) * FeraConstants.TWAP_OBS_SPACING_SEC,
            FeraConstants.RWA_TWAP_WINDOW,
            "CARD*SPACING must span the max TWAP window"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 1. Effective span reaches the configured window: a short late spike is DILUTED across
    //    ~WINDOW seconds of history, whereas a short-window read still sees it (proves averaging).
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_R23_windowDoesNotCollapseUnderFastBlocks() public {
        uint256 t = T0;

        // Phase 1 — build > WINDOW seconds of baseline history near tick 0. Checkpoints freeze ~100s
        // apart (spacing = 90s), so 24 steps span ~2400s of REAL time in the 24-slot ring.
        for (uint256 i; i < 24; ++i) {
            t += 100;
            vm.warp(t);
            _swap(i % 2 == 0, -1e15); // ~symmetric ⇒ tick oscillates tightly around 0
        }
        (int24 twapBaseline, bool readyBase) = hook.consultTwapTick(id, WINDOW);
        assertTrue(readyBase, "no >=window anchor after building history");
        assertLt(_abs(int256(twapBaseline)), 60, "baseline TWAP not near 0");

        // Phase 2 — FAST-BLOCK BURST: push the tick hard and HOLD it for ~120s of 1s "blocks".
        _swap(false, -20_000e18); // large one-sided push (raises tick)
        for (uint256 i; i < 120; ++i) {
            t += 1;
            vm.warp(t);
            _swap(false, -20e18); // keep pressure so the tick stays elevated
        }

        int24 spot = _tick();
        assertGt(spot, 2_000, "spike did not move the tick enough to be a meaningful test");

        // Read immediately after a swap so head.ts == now (no live-tick extrapolation in play).
        (int24 twapLong,) = hook.consultTwapTick(id, WINDOW); // averages ~1800s
        (int24 twapShort, bool readyShort) = hook.consultTwapTick(id, 90); // averages ~the burst
        assertTrue(readyShort, "short window not ready");

        // The 1800s TWAP is still dominated by the long tick-0 baseline: the ~120s spike is a small
        // fraction of the window, so twapLong stays far below spot. Pre-fix (collapsed ~seconds
        // window) twapLong would ≈ spot.
        assertLt(int256(twapLong), int256(spot) / 4, "R-23: long TWAP collapsed toward the spike");
        // The short window, by contrast, DOES reflect the spike — proving the oracle is live and the
        // contrast is real (the long window genuinely averages ~WINDOW seconds of history).
        assertGt(int256(twapShort), int256(twapLong) * 3, "short window failed to see the spike");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 2. Same-block manipulation still cannot move the TWAP (unchanged guarantee under R-23).
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_R23_sameBlockSwapCannotMoveTwap() public {
        uint256 t = T0;
        for (uint256 i; i < 12; ++i) {
            t += 100;
            vm.warp(t);
            _swap(i % 2 == 0, -1e15);
        }
        (int24 twapBefore,) = hook.consultTwapTick(id, WINDOW);

        // In the SAME block (no warp): a big spike swap, then read the TWAP.
        _swap(false, -20_000e18);
        int24 spot = _tick();
        assertGt(spot, 2_000, "spike too small");

        (int24 twapAfter,) = hook.consultTwapTick(id, WINDOW);
        // The spike swap advanced head.ts to `now`, so the (now − head.ts) extrapolation term is 0 —
        // the manipulated tick contributes nothing to a same-block read.
        assertEq(twapAfter, twapBefore, "same-block swap moved the TWAP (manipulation not excluded)");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 3. GAS-1 (§5): the afterSwap oracle write (+ beforeSwap fee quote) stays within the ≤40k
    //    combined hook swap-path budget. Measured warm/steady-state via direct pranked calls.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_R23_afterSwapGasWithinBudget() public {
        uint256 t = T0;
        // Warm the pool + fill the observation ring so we measure steady-state cost (all ring slots
        // warm), not first-touch cold SSTOREs. 26 checkpoints ≥ 24 slots ⇒ ring fully cycled.
        for (uint256 i; i < 26; ++i) {
            t += 100;
            vm.warp(t);
            _swap(i % 2 == 0, -1e15);
        }

        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(int128(-1e15), int128(9e14));

        // Measure via the onlyPoolManager entry points (msg.sender == the real manager). Numbers
        // INCLUDE ~2.6k external-CALL overhead each, so the true internal cost is lower (conservative).
        vm.startPrank(address(manager));
        uint256 g0 = gasleft();
        hook.beforeSwap(address(this), pkey, sp, "");
        uint256 gBefore = g0 - gasleft();

        // Common-case afterSwap: advance the floating head IN PLACE (not a checkpoint rotation).
        t += 5;
        vm.warp(t);
        uint256 g1 = gasleft();
        hook.afterSwap(address(this), pkey, sp, delta, "");
        uint256 gAfter = g1 - gasleft();
        vm.stopPrank();

        emit log_named_uint("beforeSwap gas (incl ~2.6k call overhead)", gBefore);
        emit log_named_uint("afterSwap gas (oracle head-advance, incl ~2.6k call overhead)", gAfter);
        emit log_named_uint("combined", gBefore + gAfter);
        assertLt(gBefore + gAfter, 40_000, "GAS-1: hook swap-path over the 40k budget");
    }
}
