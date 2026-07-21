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

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Vault v3 lifecycle over a real v4 PoolManager: base+limit+idle createBaseLimitPool →
///         tranche deposit → cooldown → withdraw; R-12 first-depositor defense per tranche; INV-11
///         (deposits pausable + TWAP-gated, withdrawals never); the immutable [50,500]bp gate
///         bounds (Gamma lesson). The legacy MEME ladder + drip + INV-5″ guarded-recenter surface
///         is removed (contracts/VAULT_STRATEGY_V3.md item 1) — its gate-matrix coverage now lives
///         in test/integration/BaseLimitStrategy.t.sol.
contract VaultLifecycleTest is Deployers {
    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;

    PoolKey internal poolKey;
    PoolId internal id;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant MIN_LIQ = 1_000;
    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant COOLDOWN = 3_600;
    // v3.5 (Finding-2 fix): a cooldownExempt address on a MEME pool now waits JIT_PENALTY_WINDOW_MEME
    // (1800s) + EXEMPT_WITHDRAW_MARGIN_SEC (600s) instead of the full COOLDOWN — never zero.
    uint256 internal constant EXEMPT_FLOOR = 2_400;

    function setUp() public {
        vm.warp(T0);
        deployFreshManager();
        (currency0, currency1) = deployAndMint2Currencies(); // mints 2**255 of each to this contract

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x5555) << 14));

        // keeper = owner = this test (so we can createPool / pause / strategize).
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), IAnchorStaking(address(0)), address(shareImpl), address(this), address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // v3.3 permissionless creation: team-curation lever must be set before pool creation.
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        id = vault.createBaseLimitPool(poolKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "FERA-LP", "fLP");

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
    }

    function _share() internal view returns (IERC20) {
        return IERC20(vault.shareToken(id, 0));
    }

    // ── base+limit+idle shape: 2 tranches (Steady/Active), one BASE band each at genesis ─────
    function test_createBaseLimitPool_shape() public view {
        assertEq(vault.trancheCount(id), 2, "base+limit pool ships Steady + Active");
        assertEq(vault.bandCount(id, 0), 1, "one BASE band at genesis (Steady)");
        assertEq(vault.bandCount(id, 1), 1, "one BASE band at genesis (Active)");

        (int24 lo0, int24 hi0,, bool p0) = vault.bandAt(id, 0, 0);
        assertTrue(p0, "the genesis band is principal (BASE)");
        assertTrue(lo0 < 0 && hi0 > 0, "base straddles the genesis spot");
    }

    // ── R-12: first-depositor / share-inflation defense (per tranche) ────────────────────────
    function test_R12_firstDepositLocksMinimumLiquidity() public {
        uint256 shares = vault.deposit(id, 0, 100e18, 100e18, 0);

        assertEq(_share().balanceOf(DEAD), MIN_LIQ, "minimum liquidity not locked");
        assertEq(_share().balanceOf(address(this)), shares, "depositor shares mismatch");
        assertGt(shares, 0, "no shares minted");
        assertEq(_share().totalSupply(), shares + MIN_LIQ, "total supply != shares + locked");

        // The single BASE band is funded.
        (,, uint128 l0,) = vault.bandAt(id, 0, 0);
        assertGt(l0, 0, "base band unfunded");
    }

    /// A second depositor of the same size gets ~proportional shares (ratio-matched pro-rata add).
    function test_R12_secondDepositorProportional() public {
        uint256 shares1 = vault.deposit(id, 0, 100e18, 100e18, 0);
        uint256 shares2 = vault.deposit(id, 0, 100e18, 100e18, 0);
        assertApproxEqRel(shares2, shares1, 0.01e18, "second depositor not proportional");
    }

    // ── deposit → cooldown → withdraw round trip ─────────────────────────────────────────────
    function test_depositWithdrawRoundTrip() public {
        uint256 bal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 shares = vault.deposit(id, 0, 100e18, 100e18, 0);

        vm.warp(block.timestamp + COOLDOWN); // PARAMS.md#DEPOSIT_COOLDOWN_SEC
        (uint256 out0, uint256 out1) = vault.withdraw(id, 0, shares, 0, 0);

        assertGt(out0 + out1, 0, "withdrew nothing");
        assertEq(_share().balanceOf(address(this)), 0, "shares not burned");
        // No fees flowed: round trip returns ≤ deposit (rounding dust stays in the pool — R-17).
        uint256 bal0After = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        assertLe(bal0After, bal0Before, "value created from nothing");
        assertApproxEqRel(bal0After, bal0Before, 0.001e18, "round trip lost >10bp");
    }

    // ── PARAMS §D2: deposit cooldown blocks only the depositor's own fresh redemption ────────
    function test_cooldown_blocksOwnEarlyWithdraw() public {
        uint256 shares = vault.deposit(id, 0, 10e18, 10e18, 0);

        vm.expectRevert(IFeraVault.CooldownActive.selector);
        vault.withdraw(id, 0, shares, 0, 0);

        vm.warp(block.timestamp + COOLDOWN);
        (uint256 out0,) = vault.withdraw(id, 0, shares, 0, 0);
        assertGt(out0, 0, "withdraw after cooldown failed");
    }

    /// The cooldown is per-user: another depositor's deposit does not re-arm mine.
    function test_cooldown_isPerUser() public {
        uint256 shares = vault.deposit(id, 0, 10e18, 10e18, 0);
        vm.warp(block.timestamp + COOLDOWN);

        address bob = makeAddr("bob");
        MockERC20(Currency.unwrap(currency0)).transfer(bob, 10e18);
        MockERC20(Currency.unwrap(currency1)).transfer(bob, 10e18);
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vault.deposit(id, 0, 1e18, 1e18, 0);
        vm.stopPrank();

        (uint256 out0,) = vault.withdraw(id, 0, shares, 0, 0); // my cooldown lapsed — must work
        assertGt(out0, 0, "another user's deposit re-armed my cooldown");
    }

    // ── cooldownExempt: the future-aggregator DoS fix (contracts/INDEX_VAULT_SPEC.md §12) ────
    // A shared depositor (e.g. an index vault) would otherwise have EVERY unrelated user's deposit
    // re-arm its cooldown and freeze ITS depositors' withdrawals. The owner-set exemption lifts
    // ONLY the timing check for that one address; every other guard still applies identically.
    /// v3.5 (Finding-2 fix): exemption is no longer a full bypass — an exempt address still cannot
    /// withdraw IMMEDIATELY (that would let it deposit-then-instantly-withdraw in one tx, forcing its
    /// own mandatory fee checkpoint to land inside the JIT-forfeiture window it just armed and donate
    /// its own accrued fees away). It only needs to clear a SHORT floor (JIT window + margin), well
    /// under the full hour-long DEPOSIT_COOLDOWN_SEC a non-exempt address must wait.
    function test_cooldownExempt_blocksImmediateWithdraw_allowsAfterShortFloor() public {
        vault.setCooldownExempt(address(this), true);
        uint256 shares = vault.deposit(id, 0, 10e18, 10e18, 0);

        // No vm.warp — even exempt, this must still revert (closes the atomic self-arm-then-harvest
        // JIT-donate siphon, memo finding #2).
        vm.expectRevert(IFeraVault.CooldownActive.selector);
        vault.withdraw(id, 0, shares, 0, 0);

        // Short of the FULL cooldown, but past the exempt floor — still succeeds unlike a non-exempt
        // address, which would need to wait the full COOLDOWN (proven in test_cooldown_blocksImmediateWithdraw).
        vm.warp(block.timestamp + EXEMPT_FLOOR);
        assertLt(EXEMPT_FLOOR, COOLDOWN, "exempt floor must stay meaningfully shorter than the full cooldown");
        (uint256 out0,) = vault.withdraw(id, 0, shares, 0, 0);
        assertGt(out0, 0, "exempt address could not withdraw after clearing its short floor");
    }

    function test_cooldownExempt_onlyOwner() public {
        vm.prank(notOwnerForCooldownTest());
        vm.expectRevert();
        vault.setCooldownExempt(address(this), true);
    }

    function test_cooldownExempt_zeroAddressRejected() public {
        vm.expectRevert(IFeraVault.ZeroAddress.selector);
        vault.setCooldownExempt(address(0), true);
    }

    /// Exempting address A must not leak the exemption to address B (no global bypass).
    function test_cooldownExempt_isPerAddress() public {
        address alice = address(this);
        address bob = makeAddr("bobExempt");
        vault.setCooldownExempt(alice, true); // alice exempt, bob is NOT

        uint256 sharesAlice = vault.deposit(id, 0, 10e18, 10e18, 0);
        vm.warp(block.timestamp + EXEMPT_FLOOR); // exempt floor, not the full cooldown (v3.5)
        (uint256 out0,) = vault.withdraw(id, 0, sharesAlice, 0, 0);
        assertGt(out0, 0, "exempt alice should withdraw after clearing the short floor");

        MockERC20(Currency.unwrap(currency0)).transfer(bob, 10e18);
        MockERC20(Currency.unwrap(currency1)).transfer(bob, 10e18);
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        uint256 sharesBob = vault.deposit(id, 0, 10e18, 10e18, 0);
        vm.expectRevert(IFeraVault.CooldownActive.selector);
        vault.withdraw(id, 0, sharesBob, 0, 0);
        vm.stopPrank();
    }

    /// The exemption only shortens the timing check (v3.5: to a JIT-window-sized floor, never zero)
    /// — an exempt address still cannot withdraw more than its real share balance, and the
    /// minAmount0/minAmount1 slippage bound still reverts.
    function test_cooldownExempt_stillBoundedByRealAccounting() public {
        vault.setCooldownExempt(address(this), true);
        uint256 shares = vault.deposit(id, 0, 10e18, 10e18, 0);
        vm.warp(block.timestamp + EXEMPT_FLOOR); // clear the exempt floor (v3.5) first

        vm.expectRevert(); // ERC20 underflow burning more than the real balance — no backdoor mint
        vault.withdraw(id, 0, shares + 1, 0, 0);

        vm.expectRevert(IFeraVault.Slippage.selector);
        vault.withdraw(id, 0, shares, type(uint256).max, type(uint256).max);
    }

    function notOwnerForCooldownTest() internal returns (address) {
        return makeAddr("notOwnerCooldown");
    }

    // ── INV-11: deposits pausable, withdrawals never ─────────────────────────────────────────
    function test_INV11_depositPausable_withdrawNever() public {
        uint256 shares = vault.deposit(id, 0, 10e18, 10e18, 0);

        vault.pauseDeposits(id);
        assertTrue(vault.depositsPaused(id));

        vm.expectRevert(IFeraVault.DepositsPaused.selector);
        vault.deposit(id, 0, 1e18, 1e18, 0);

        // Withdrawals must still work while deposits are paused (INV-11).
        vm.warp(block.timestamp + COOLDOWN);
        (uint256 out0, uint256 out1) = vault.withdraw(id, 0, shares / 2, 0, 0);
        assertGt(out0 + out1, 0, "withdraw blocked while paused");
    }

    // ── OD-V5 / Gamma: the TWAP gate's legal range [50,500]bp is immutable in code ───────────
    function test_gateBounds_immutableLegalRange() public {
        vm.expectRevert(IFeraVault.GateOutOfBounds.selector);
        vault.setDepositTwapGate(49); // below the code floor

        vm.expectRevert(IFeraVault.GateOutOfBounds.selector);
        vault.setDepositTwapGate(501); // above the code ceiling — Gamma's exact failure mode

        vault.setDepositTwapGate(50);
        assertEq(vault.depositTwapGateBps(), 50);
        vault.setDepositTwapGate(500);
        assertEq(vault.depositTwapGateBps(), 500);

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        vault.setDepositTwapGate(200);
    }

    // ── access control ───────────────────────────────────────────────────────────────────────
    /// @notice v3.3 (contracts/VAULT_STRATEGY_V3.md §11): pool creation is now PERMISSIONLESS — the
    ///         former `onlyKeeper` gate is gone. A random, non-keeper caller may create a NEW pool
    ///         (distinct key from `poolKey`, which is already initialized by `setUp`) against the
    ///         SAME already-allowlisted quote asset. The comprehensive permissionless-creation +
    ///         quote-allowlist + RWA-feed-registry + emissions-eligible-flag matrix lives in
    ///         `test/integration/PermissionlessPoolCreation.t.sol`.
    function test_createBaseLimitPool_permissionless_notKeeperSucceeds() public {
        PoolKey memory freshKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 100, // distinct from setUp's poolKey (spacing 60) ⇒ distinct pool id
            hooks: IHooks(address(hook))
        });
        vm.prank(makeAddr("notKeeper"));
        PoolId freshId = vault.createBaseLimitPool(freshKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "x", "x");
        assertEq(vault.trancheCount(freshId), 2, "permissionless creation must still build both tranches");
    }

    function test_pauseDeposits_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(); // Ownable unauthorized
        vault.pauseDeposits(id);
    }

    function test_unknownTranche_reverts() public {
        vm.expectRevert(IFeraVault.UnknownTranche.selector);
        vault.deposit(id, 2, 1e18, 1e18, 0); // base+limit pools have exactly 2 tranches (0,1)
    }
}
