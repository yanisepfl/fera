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

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title  Permissionless-pool lens PoC — `createBaseLimitPool` does NOT validate `key.hooks`.
/// @notice LENS: permissionless pool creation / fake pools (stage 4, contracts/VAULT_STRATEGY_V3.md
///         §11; contracts/THREAT_MODEL.md §11.1 / §12).
///
///         FINDING (H-1). `FeraVault.createBaseLimitPool` requires the DESIGNATED QUOTE asset to be
///         team-allowlisted and (for RWA) the oracle feed to be team-approved — but it NEVER checks
///         that the pool's `key.hooks` is the Vault's own immutable `hook`. Because pool creation is
///         permissionless (v3.3), any address can register, WITH THE VAULT, a pool whose ACTUAL v4
///         hook is `address(0)` (a plain static-fee pool) or an attacker-controlled hook — while
///         still designating a genuinely-allowlisted quote asset (e.g. WETH) so both curation levers
///         pass.
///
///         WHY IT MATTERS. The entire manipulation-resistance argument for the fee-routing self-swap
///         (§9), the rebalance self-swap (`selfSwap`/`_cbSelfSwap`), and `withdrawSingle` rests on
///         one precondition, stated verbatim in THREAT_MODEL §11.1: "`_doSelfSwap`'s minOut is
///         computed from `_twapImpliedOut(id,...)`, which reads `hook.consultTwapTick(id,...)` — the
///         SAME manipulation-resistant cumulative-tick oracle". That oracle is ONLY ever populated
///         when swaps route through the REAL FeraHook's callbacks. A pool whose `key.hooks` is NOT
///         the real hook never feeds it: `consultTwapTick(id,...)` returns `ready == false`, and
///         `_poolTwapPrice` (read below) then FALLS BACK TO RAW SPOT from `poolManager.getSlot0(id)`
///         — an atomically attacker-suppliable price the creator, who owns 100% of their own pool's
///         liquidity, moves at will inside the very transaction the bounded swap executes in. The
///         "bound" thus binds to a number the attacker sets → the TWAP-vs-execution guard is void
///         for that pool, defeating §11.1 / §12.2's central refutation.
///
///         FIX (H-1, applied in the Fix stage). `createBaseLimitPool` now requires
///         `address(key.hooks) == address(hook)` (new `IFeraVault.WrongHook` error), the symmetric
///         counterpart to FeraHook._beforeInitialize's `sender == vault` guard. The tests below are
///         FLIPPED from the auditor's EXPLOITABLE state to the fixed state: the foreign/zero-hook
///         registration that previously SUCCEEDED (fully-registered pool, `isConfigured == false`,
///         `consultTwapTick.ready == false`) now REVERTS `WrongHook` — for `key.hooks == address(0)`
///         AND for any attacker-deployed hook address — while the real-hook control pool is
///         unaffected. See security/hardening/09-permissionless-pools-audit.md.
contract PermissionlessPoolHookBypassPoC is Deployers {
    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;

    address internal stakersAddr = makeAddr("stakers");
    address internal treasuryAddr = makeAddr("treasury");
    address internal opsAddr = makeAddr("ops");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant T0 = 10_000_000;
    uint24 internal constant STATIC_FEE = 3000; // 0.30% — a plain, hookless static-fee pool

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(stakersAddr, treasuryAddr, opsAddr);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0xB17A) << 14));
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

        // The team allowlists a genuinely liquid quote asset (currency0 stands in for WETH/USDG).
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
    }

    /// @dev The intended pool shape: `key.hooks == address(hook)` (real FeraHook), dynamic fee.
    function _realHookKey(int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev The attacker's pool shape: NO hook (address(0)) + a static fee. v4's
    ///      `Hooks.isValidHookAddress` accepts a zero hook as long as the fee is NOT dynamic, so this
    ///      is a perfectly valid `poolManager.initialize` — but the real FeraHook's callbacks never
    ///      run for it. (An attacker-DEPLOYED hook with matching flag bits would work identically for
    ///      a dynamic-fee variant; address(0) is simply the cheapest instance of the same class.)
    function _foreignHookKey(int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: STATIC_FEE,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // PoC 1 (FLIPPED to the fixed state) — a foreign/zero-hook pool can NO LONGER be registered.
    //   BEFORE the fix: `createBaseLimitPool(key.hooks == address(0))` SUCCEEDED — trancheCount == 2,
    //                   regime set, share clones deployed, yet hook.isConfigured == false and
    //                   consultTwapTick.ready == false (bound degraded to spot). [auditor EXPLOITABLE]
    //   AFTER the fix:  the same call REVERTS `WrongHook`; only the real-hook pool is accepted.
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function test_H1_fixed_foreignHookPool_reverts_WrongHook() public {
        // Positive control: the intended pool. Created through the real hook ⇒ the hook's
        // `_beforeInitialize` runs (sender==vault), binds the regime, and SEEDS the TWAP oracle.
        PoolId realId = _createAs(attacker, _realHookKey(60), FeraTypes.Regime.MEME, address(0), true);
        assertTrue(hook.isConfigured(realId), "control: real-hook pool must still be configured on the hook");
        assertEq(vault.trancheCount(realId), 2, "control: real-hook pool must still register normally");

        // AFTER FIX: `key.hooks == address(0)` (v4's cheapest hook-bypass — valid because the fee is
        //            static, so `Hooks.isValidHookAddress` accepts it) is now rejected up front.
        PoolKey memory zeroHookKey = _foreignHookKey(60);
        vm.prank(attacker);
        vm.expectRevert(IFeraVault.WrongHook.selector);
        vault.createBaseLimitPool(zeroHookKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "POOL", "P");

        // AFTER FIX: an attacker-DEPLOYED hook address (the dynamic-fee variant of the same class) is
        //            likewise rejected — the Vault only accepts its own immutable hook. The check
        //            fires before `poolManager.initialize`, so no v4-side validation is even reached.
        PoolKey memory attackerHookKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(makeAddr("attackerHook"))
        });
        vm.prank(attacker);
        vm.expectRevert(IFeraVault.WrongHook.selector);
        vault.createBaseLimitPool(attackerHookKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "POOL", "P");

        // Consequence of the revert: the foreign-hook pool never exists at the Vault level, so it can
        // never masquerade as a real pool. (Before the fix, vault.trancheCount(fakeId) == 2 here.)
        PoolId fakeId = zeroHookKey.toId();
        assertEq(vault.trancheCount(fakeId), 0, "AFTER FIX: foreign-hook pool was never registered");
        assertFalse(hook.isConfigured(fakeId), "AFTER FIX: no fake pool to bypass the hook");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // PoC 2 (FLIPPED) — the degraded "trades heavily but never arms the real TWAP" state is now
    //   UNREACHABLE by construction: the foreign-hook pool cannot be created, so no volume can ever
    //   flow through a vault-registered pool that bypasses the oracle. The real-hook control still
    //   arms its oracle exactly as before.
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function test_H1_fixed_foreignHookPool_canNeverReachDegradedTradingState() public {
        // Real-hook pool: deposit + swap ⇒ the hook records observations (control, unchanged by fix).
        PoolKey memory rk = _realHookKey(60);
        PoolId realId = _createAs(address(this), rk, FeraTypes.Regime.MEME, address(0), true);
        vault.deposit(realId, 0, 500e18, 500e18, 0);
        swap(rk, true, -2e18, "");
        swap(rk, false, -2e18, "");
        (, bool realHasObs) = hook.twapObservationAge(realId);
        assertTrue(realHasObs, "control: swapping a real-hook pool arms the hook's TWAP oracle");

        // AFTER FIX: the foreign-hook pool can never be created — so the depositor-facing pool that
        // previously accepted `deposit` + `swap` volume while feeding NOTHING to the real oracle no
        // longer exists. (Before the fix this creation SUCCEEDED and fakeHasObs stayed false forever.)
        PoolKey memory fk = _foreignHookKey(60);
        vm.expectRevert(IFeraVault.WrongHook.selector);
        vault.createBaseLimitPool(fk, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "POOL", "P");
    }

    function _createAs(address who, PoolKey memory key, FeraTypes.Regime regime, address feed, bool quoteIsToken0)
        internal
        returns (PoolId)
    {
        vm.prank(who);
        return vault.createBaseLimitPool(key, regime, feed, SQRT_PRICE_1_1, quoteIsToken0, "POOL", "P");
    }
}
