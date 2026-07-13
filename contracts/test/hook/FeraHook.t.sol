// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeraHook} from "../../src/FeraHook.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice v2 hook unit tests: the D-14 permission set + VERIFIED 0x25C3 salt target, INV-1″
///         (no before-liquidity gates exist at all), INV-2 (swaps never gated, never skimmed,
///         swap path delta-flagless), and the F-8 `PoolRegistered` init event.
/// @dev    The test contract IS the pool manager (poolManager immutable = address(this)), so it can
///         invoke the onlyPoolManager hook entry points. The hook is etched at a flag-valid address.
///         The JIT penalty paths (which need a REAL manager for donate/6909 custody) are covered in
///         test/hook/JitPenalty.t.sol.
contract FeraHookTest is Test {
    FeraHook internal hook;
    address internal vault = makeAddr("vault");

    PoolKey internal key;

    /// @dev The v0.5 (D-14) flag set — must equal FeraConstants.HOOK_FLAG_TARGET (0x25C3).
    function _v2Flags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
    }

    function setUp() public {
        // Low 14 bits must equal the flag set (0x25C3, per MASTER_SPEC §5 v0.5); high bits are a
        // namespace. deployCodeTo etches at exactly this address; the constructor self-validates.
        address hookAddr = address(_v2Flags() | (uint160(0x4444) << 14));

        // poolManager = this test contract, so we can call the onlyPoolManager entry points.
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(IPoolManager(address(this)), vault), hookAddr);
        hook = FeraHook(hookAddr);

        key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
    }

    // ── D-14 flag arithmetic: the provisional 0x25C3 target is VERIFIED here in CI ──────────
    function test_flagTarget_is0x25C3_verified() public pure {
        // beforeInitialize 0x2000 + afterAdd 0x0400 + afterRemove 0x0100 + beforeSwap 0x0080
        // + afterSwap 0x0040 + afterAddRD 0x0002 + afterRemoveRD 0x0001 = 0x25C3.
        assertEq(uint256(_v2Flags()), 0x25C3, "flag arithmetic drifted from MASTER_SPEC section 5");
        assertEq(uint256(FeraConstants.HOOK_FLAG_TARGET), uint256(_v2Flags()), "constant drifted");
    }

    // ── permission set (v0.5): before-liquidity DROPPED, after-liquidity + RD ADDED ─────────
    function test_permissions_v2Set() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize, "beforeInitialize");
        assertTrue(p.afterAddLiquidity, "afterAddLiquidity");
        assertTrue(p.afterRemoveLiquidity, "afterRemoveLiquidity");
        assertTrue(p.beforeSwap, "beforeSwap");
        assertTrue(p.afterSwap, "afterSwap");
        assertTrue(p.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta");
        assertTrue(p.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta");

        // INV-1″: the liquidity GATES are gone — structurally impossible to block an add/remove.
        assertFalse(p.beforeAddLiquidity, "beforeAddLiquidity must be DROPPED (INV-1 doubleprime)");
        assertFalse(p.beforeRemoveLiquidity, "beforeRemoveLiquidity must be DROPPED (INV-1 doubleprime)");

        // INV-2: the SWAP path stays delta-flagless — physically incapable of skimming a swap.
        assertFalse(p.beforeSwapReturnDelta, "beforeSwapReturnDelta must be false (INV-2)");
        assertFalse(p.afterSwapReturnDelta, "afterSwapReturnDelta must be false (INV-2)");
        assertFalse(p.afterInitialize, "afterInitialize off");
        assertFalse(p.beforeDonate, "beforeDonate off");
        assertFalse(p.afterDonate, "afterDonate off");
    }

    // ── INV-1″: the before-liquidity entry points are UNIMPLEMENTED (no gate exists) ────────
    ModifyLiquidityParams internal mlp =
        ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: 0});

    function test_INV1pp_noBeforeLiquidityGateExists() public {
        // v4 will never call these (flags off); if anything ever did, they revert
        // HookNotImplemented — there is no code path that could gate by identity.
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(vault, key, mlp, "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(makeAddr("alice"), key, mlp, "");
    }

    // ── beforeInitialize: vault-bound config + F-8 PoolRegistered ────────────────────────────
    function test_init_emitsPoolRegistered_andBindsRegime() public {
        vm.prank(vault);
        hook.registerRegime(key, FeraTypes.Regime.RWA);

        PoolId id = key.toId();
        vm.expectEmit(true, false, false, true, address(hook));
        emit IFeraHook.PoolRegistered(
            PoolId.unwrap(id), Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), uint8(FeraTypes.Regime.RWA)
        );
        bytes4 sel = hook.beforeInitialize(vault, key, 0);
        assertEq(sel, IHooks.beforeInitialize.selector);

        assertTrue(hook.isConfigured(id), "not configured");
        assertEq(uint8(hook.regimeOf(id)), uint8(FeraTypes.Regime.RWA), "regime not bound");
    }

    function test_init_revertsForNonVaultSender() public {
        vm.prank(vault);
        hook.registerRegime(key, FeraTypes.Regime.MEME);
        vm.expectRevert(IFeraHook.OnlyVault.selector);
        hook.beforeInitialize(makeAddr("alice"), key, 0);
    }

    function test_init_revertsWithoutRegisteredRegime() public {
        vm.expectRevert(IFeraHook.PoolNotConfigured.selector);
        hook.beforeInitialize(vault, key, 0);
    }

    function test_init_revertsForStaticFeePool() public {
        PoolKey memory staticKey = key;
        staticKey.fee = 3000; // NOT the dynamic-fee sentinel
        vm.prank(vault);
        hook.registerRegime(staticKey, FeraTypes.Regime.MEME);
        vm.expectRevert(IFeraHook.NotDynamicFeePool.selector);
        hook.beforeInitialize(vault, staticKey, 0);
    }

    function test_registerRegime_onlyVault() public {
        vm.prank(makeAddr("alice"));
        vm.expectRevert(IFeraHook.OnlyVault.selector);
        hook.registerRegime(key, FeraTypes.Regime.MEME);
    }

    // ── INV-2: swaps are never gated; hook never skims ───────────────────────────────────────
    function test_INV2_beforeSwap_openToEverySender() public {
        address[3] memory senders = [vault, makeAddr("bot"), address(0)];
        for (uint256 i; i < senders.length; ++i) {
            _assertSwapAllowed(senders[i], true);
            _assertSwapAllowed(senders[i], false);
        }
    }

    function _assertSwapAllowed(address sender, bool zeroForOne) internal {
        SwapParams memory sp = SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        (bytes4 sel, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(sender, key, sp, "");

        assertEq(sel, IHooks.beforeSwap.selector, "beforeSwap wrong selector");
        // INV-2: no swap-taking delta — the hook returns ZERO_DELTA (cannot skim the swap).
        assertEq(
            BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA), "non-zero delta"
        );

        // The fee carries the dynamic OVERRIDE flag so v4-core applies it as an LP fee (not protocol).
        assertTrue((fee & LPFeeLibrary.OVERRIDE_FEE_FLAG) != 0, "override flag missing");

        // Stripped fee is a bounded LP fee within the MEME regime band (default regime = MEME).
        // v2: floor is 3400 pips (PT-3 freeze).
        uint24 stripped = fee & ~uint24(LPFeeLibrary.OVERRIDE_FEE_FLAG);
        assertGe(stripped, FeraConstants.MEME_FEE_FLOOR_PIPS, "fee below floor");
        assertLe(stripped, FeraConstants.MEME_FEE_CEIL_PIPS, "fee above ceiling");
        assertLe(stripped, LPFeeLibrary.MAX_LP_FEE, "fee above v4 max");
    }

    /// The onlyPoolManager guard: only the real manager may drive the hook's entry points
    /// (identity of the LP/trader behind it is irrelevant — INV-1″/INV-2 sender-neutrality).
    function test_onlyPoolManagerGuard() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(vault, key, SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0}), "");
    }

    /// The public immutable Vault address is exactly the one bound at construction.
    function test_vaultImmutable() public view {
        assertEq(hook.vault(), vault);
    }

    /// The regime-scoped JIT windows are the frozen PARAMS values (MEME 1800 / RWA 600).
    function test_jitWindows_frozenValues() public {
        // Unregistered pool defaults to MEME window (regime 0).
        assertEq(hook.jitPenaltyWindow(key.toId()), 1800, "MEME window");

        vm.prank(vault);
        hook.registerRegime(key, FeraTypes.Regime.RWA);
        hook.beforeInitialize(vault, key, 0);
        assertEq(hook.jitPenaltyWindow(key.toId()), 600, "RWA window");
    }
}
