// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {FeraHook} from "../../src/FeraHook.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice INV-1″ + D-14 integration tests over a REAL v4 PoolManager:
///          - liquidity ops are permissionless (no vault gate — the router, not the Vault, LPs here)
///          - removals NEVER revert, inside or outside the JIT window
///          - fee-forfeiture math: 100% at elapsed 0, ~50% at half-window (LINEAR decay), 0 outside
///          - forfeited fees are DONATED to remaining in-range LPs
///          - fees auto-collected by an in-window ADD are withheld (no poke-and-dodge)
///          - donation fallback: if no in-range recipient remains, skip (fees returned, no revert)
contract JitPenaltyTest is Deployers {
    FeraHook internal hook;
    PoolKey internal pkey;
    PoolId internal id;

    uint256 internal constant WINDOW = 1800; // MEME JIT_PENALTY_WINDOW (frozen v2)
    int24 internal constant LO = -600;
    int24 internal constant HI = 600;
    uint256 internal constant L = 1_000e18; // per JIT position
    uint256 internal constant T0 = 1_000_000; // test epoch start

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x5A17) << 14));
        // vault = this test contract (only used for pool INITIALIZATION — liquidity is open).
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
        manager.initialize(pkey, SQRT_PRICE_1_1); // sender == vault == this

        vm.warp(T0);
        // Honest anchor liquidity: a small full-range "tail" held throughout — the donation
        // recipient of last resort (mirrors the vault's tail band).
        _modify(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(1e15), bytes32("tail"));
        // Let the tail's own window lapse so it is never withheld/penalized in these tests.
        vm.warp(T0 + WINDOW + 1);
    }

    function _modify(int24 lo, int24 hi, int256 dL, bytes32 salt) internal returns (BalanceDelta d) {
        d = modifyLiquidityRouter.modifyLiquidity(
            pkey, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: dL, salt: salt}), ""
        );
    }

    function _swapIn(uint256 amountIn) internal {
        swap(pkey, true, -int256(amountIn), ""); // zeroForOne exactIn — fees accrue in token0
    }

    /// @dev Forfeit events emitted during `recorded` logs, summed for token0.
    function _forfeited0(Vm.Log[] memory logs) internal pure returns (uint256 total, uint256 count) {
        bytes32 topic = keccak256("JitPenaltyApplied(bytes32,address,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) {
                (uint256 f0,) = abi.decode(logs[i].data, (uint256, uint256));
                total += f0;
                ++count;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // INV-1″ — permissionless, never blocked
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// A non-vault LP (the router) adds AND removes freely; the remove inside the window does NOT
    /// revert even while a penalty applies.
    function test_INV1pp_addRemove_permissionless_neverReverts() public {
        _modify(LO, HI, int256(L), bytes32("jit"));
        _swapIn(1e18); // accrue fees
        // Same-timestamp remove: deepest possible penalty — and it MUST still succeed.
        BalanceDelta d = _modify(LO, HI, -int256(L), bytes32("jit"));
        assertGt(d.amount0(), 0, "principal did not exit");
    }

    /// Fuzz: removal never reverts at ANY elapsed time in/around the window.
    function testFuzz_INV1pp_removeNeverReverts(uint256 wait) public {
        wait = bound(wait, 0, 2 * WINDOW);
        _modify(LO, HI, int256(L), bytes32("fz"));
        _swapIn(1e18);
        vm.warp(block.timestamp + wait);
        BalanceDelta d = _modify(LO, HI, -int256(L), bytes32("fz")); // must not revert
        assertGt(d.amount0(), 0, "principal did not exit");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Penalty math — linear decay (PARAMS.md#JIT_PENALTY_DECAY)
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// Three identical positions accrue identical fees from one swap. s1 exits at elapsed 0
    /// (100% forfeit — receives principal only), s2 at half-window (50% of its accrued kept),
    /// s3 after the window (keeps everything incl. donated shares). With a dust-sized tail,
    /// donations flow ~fully to the surviving identical positions, giving closed-form ratios.
    function test_penalty_linearDecay_fullHalfZero() public {
        uint256 start = block.timestamp;
        _modify(LO, HI, int256(L), "s1");
        _modify(LO, HI, int256(L), "s2");
        _modify(LO, HI, int256(L), "s3");
        _swapIn(10e18);

        // s1: elapsed 0 ⇒ forfeit 100% of its accrued fees A. received1 = principal only.
        vm.recordLogs();
        BalanceDelta d1 = _modify(LO, HI, -int256(L), "s1");
        (uint256 pen1, uint256 n1) = _forfeited0(vm.getRecordedLogs());
        assertEq(n1, 1, "s1: expected one JitPenaltyApplied");
        assertGt(pen1, 0, "s1: full forfeit must be nonzero");

        // s2: elapsed = WINDOW/2 ⇒ forfeit exactly half of its accrued (linear decay).
        vm.warp(start + WINDOW / 2);
        vm.recordLogs();
        BalanceDelta d2 = _modify(LO, HI, -int256(L), "s2");
        (uint256 pen2, uint256 n2) = _forfeited0(vm.getRecordedLogs());
        assertEq(n2, 1, "s2: expected one JitPenaltyApplied");

        // s3: elapsed ≥ WINDOW ⇒ penalty 0, no event.
        vm.warp(start + WINDOW);
        vm.recordLogs();
        BalanceDelta d3 = _modify(LO, HI, -int256(L), "s3");
        (, uint256 n3) = _forfeited0(vm.getRecordedLogs());
        assertEq(n3, 0, "s3: no penalty outside the window");

        uint256 r1 = uint256(uint128(d1.amount0()));
        uint256 r2 = uint256(uint128(d2.amount0()));
        uint256 r3 = uint256(uint128(d3.amount0()));

        // r1 = P (principal only). Each position accrued A = pen1 from the swap.
        // s2 accrued A + ~A/2 (s1's donation split between s2 and s3) = 1.5A; kept half: r2 ≈ P + 0.75A.
        // Verified directly: s2's forfeit event = half its accrued ⇒ kept == pen2.
        assertApproxEqRel(r2 - r1, pen2, 0.02e18, "linear decay: kept != forfeited at half-window");
        assertApproxEqRel(pen2, (pen1 * 3) / 4, 0.02e18, "s2 accrued+donated mismatch");
        // s3 kept everything: accrued 1.5A + s2's 0.75A donation ≈ 2.25A.
        assertApproxEqRel(r3 - r1, (pen1 * 9) / 4, 0.02e18, "s3 full retention mismatch");
        // Monotone: earlier exit ⇒ strictly less.
        assertLt(r1, r2, "full forfeit not below half");
        assertLt(r2, r3, "half forfeit not below zero-penalty");
    }

    /// Penalty is exactly zero outside the window: two identical positions removed after expiry
    /// at the same pool state receive identical amounts (no hidden skim).
    function test_penalty_zeroOutsideWindow_exactEquality() public {
        _modify(LO, HI, int256(L), "a");
        _modify(LO, HI, int256(L), "b");
        _swapIn(5e18);
        vm.warp(block.timestamp + WINDOW); // both windows lapse

        vm.recordLogs();
        BalanceDelta da = _modify(LO, HI, -int256(L), "a");
        BalanceDelta db = _modify(LO, HI, -int256(L), "b");
        (, uint256 n) = _forfeited0(vm.getRecordedLogs());

        assertEq(n, 0, "no JitPenaltyApplied outside window");
        assertApproxEqAbs(uint256(uint128(da.amount0())), uint256(uint128(db.amount0())), 2, "asymmetric payout");
        assertGt(da.amount0(), 0, "no fees for honest LP");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Withholding — no poke-and-dodge; custody returned intact after the window
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// Fees auto-collected by an in-window ADD are withheld in the hook (the JIT bot cannot
    /// pre-collect via a top-up), then returned in full on a post-window remove.
    function test_withholding_onInWindowAdd_returnedAfterWindow() public {
        _modify(LO, HI, int256(L), "w");
        _swapIn(5e18);

        // In-window top-up: auto-collected fees must be withheld, not paid out.
        vm.warp(block.timestamp + 60);
        _modify(LO, HI, int256(1e18), "w");

        bytes32 pk = Position.calculatePositionKey(address(modifyLiquidityRouter), LO, HI, bytes32("w"));
        (uint64 lastAdd, uint128 w0,) = hook.jitStateOf(id, pk);
        assertEq(lastAdd, uint64(block.timestamp), "window not re-armed by the add");
        assertGt(w0, 0, "in-window add fees were not withheld");

        // After the (re-armed) window: full remove returns principal + withheld fees, no penalty.
        vm.warp(block.timestamp + WINDOW);
        vm.recordLogs();
        _modify(LO, HI, -int256(L + 1e18), "w");
        (, uint256 n) = _forfeited0(vm.getRecordedLogs());
        assertEq(n, 0, "penalty applied outside window");

        (, uint128 w0After, uint128 w1After) = hook.jitStateOf(id, pk);
        assertEq(uint256(w0After) + w1After, 0, "custody not cleared");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Donation fallback (PARAMS.md#JIT_DONATION_FALLBACK) — skip when no in-range recipient
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// A second pool where the remover is the ONLY liquidity: in-window remove-all finds no
    /// in-range donation recipient ⇒ donation is skipped, nothing reverts, fees come back.
    function test_donationFallback_skipWhenNoRecipient() public {
        PoolKey memory k2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 30,
            hooks: IHooks(address(hook))
        });
        hook.registerRegime(k2, FeraTypes.Regime.MEME);
        manager.initialize(k2, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            k2, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: int256(L), salt: "solo"}), ""
        );
        swap(k2, true, -1e18, "");

        vm.recordLogs();
        BalanceDelta d = modifyLiquidityRouter.modifyLiquidity(
            k2, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: -int256(L), salt: "solo"}), ""
        );
        (, uint256 n) = _forfeited0(vm.getRecordedLogs());

        assertEq(n, 0, "donation should be SKIPPED with no in-range recipient");
        assertGt(d.amount0(), 0, "principal+fees did not exit");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // RWA window differs (600s) — regime scoping
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_regimeScopedWindow_rwa600() public view {
        assertEq(hook.jitPenaltyWindow(id), uint32(FeraConstants.JIT_PENALTY_WINDOW_MEME));
        assertEq(uint256(FeraConstants.JIT_PENALTY_WINDOW_MEME), 1800);
        assertEq(uint256(FeraConstants.JIT_PENALTY_WINDOW_RWA), 600);
    }
}
