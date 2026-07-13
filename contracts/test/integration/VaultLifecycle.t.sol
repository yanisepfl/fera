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

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Vault v2 lifecycle over a real v4 PoolManager: MEME band-ladder createPool → tranche
///         deposit → cooldown → withdraw; R-12 first-depositor defense per tranche; INV-11
///         (deposits pausable + TWAP-gated, withdrawals never); the immutable [50,500]bp gate
///         bounds (Gamma lesson); and the INV-5″ default posture (healthy pool ⇒ no recenter).
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
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), address(shareImpl), address(this), address(this)
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

        id = vault.createPool(poolKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, "FERA-LP", "fLP");

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
    }

    function _share() internal view returns (IERC20) {
        return IERC20(vault.shareToken(id, 0));
    }

    // ── D-12/D-16: MEME createPool builds the 30/40/30 single-tranche ladder ─────────────────
    function test_createPool_memeLadderShape() public view {
        assertEq(vault.trancheCount(id), 1, "MEME must be single-tranche (D-16)");
        assertEq(vault.bandCount(id, 0), 3, "ladder is 3 principal bands");

        (int24 lo0, int24 hi0,, bool p0) = vault.bandAt(id, 0, 0); // core ±k=1.3
        (int24 lo1, int24 hi1,, bool p1) = vault.bandAt(id, 0, 1); // mid ±k=2.0
        (int24 lo2, int24 hi2,, bool p2) = vault.bandAt(id, 0, 2); // tail full range
        assertTrue(p0 && p1 && p2, "all inception bands are principal");
        assertEq(lo0, -2640, "core lower");
        assertEq(hi0, 2640, "core upper");
        assertEq(lo1, -6960, "mid lower");
        assertEq(hi1, 6960, "mid upper");
        assertEq(lo2, TickMath.minUsableTick(60), "tail lower");
        assertEq(hi2, TickMath.maxUsableTick(60), "tail upper");
    }

    // ── R-12: first-depositor / share-inflation defense (per tranche) ────────────────────────
    function test_R12_firstDepositLocksMinimumLiquidity() public {
        uint256 shares = vault.deposit(id, 0, 100e18, 100e18, 0);

        assertEq(_share().balanceOf(DEAD), MIN_LIQ, "minimum liquidity not locked");
        assertEq(_share().balanceOf(address(this)), shares, "depositor shares mismatch");
        assertGt(shares, 0, "no shares minted");
        assertEq(_share().totalSupply(), shares + MIN_LIQ, "total supply != shares + locked");

        // All three ladder bands are funded.
        (,, uint128 l0,) = vault.bandAt(id, 0, 0);
        (,, uint128 l1,) = vault.bandAt(id, 0, 1);
        (,, uint128 l2,) = vault.bandAt(id, 0, 2);
        assertGt(l0, 0, "core unfunded");
        assertGt(l1, 0, "mid unfunded");
        assertGt(l2, 0, "tail unfunded");
        // Concentration sanity: core (30% of capital, ±30% band) quotes DEEPER than tail (30%, full).
        assertGt(l0, l2, "ladder not concentrated");
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

    // ── INV-5″ default posture: a healthy ladder REFUSES to recenter ─────────────────────────
    function test_INV5pp_healthyPoolRejectsRecenter() public {
        vault.deposit(id, 0, 100e18, 100e18, 0);

        assertFalse(vault.pokeDepthBreach(id), "healthy 4.1x ladder flagged as breached");
        assertEq(vault.depthBreachSince(id), 0, "breach clock armed on healthy pool");

        vm.expectRevert(IFeraVault.DepthNotBreached.selector);
        vault.recenterMeme(id, bytes32(0));
    }

    /// RWA-only actions revert on MEME (and the RWA entry rejects MEME pools).
    function test_INV5pp_memeRejectsRwaActions() public {
        vm.expectRevert(IFeraVault.NotRwa.selector);
        vault.recenter(id, -60, 60, bytes32(0));
        vm.expectRevert(IFeraVault.NotRwa.selector);
        vault.widen(id, -60, 60, bytes32(0));
        vm.expectRevert(IFeraVault.NotRwa.selector);
        vault.partialWithdraw(id, 1, bytes32(0));
    }

    /// Drip is gated by the dust floor (PARAMS.md#MEME_DRIP_MIN_SIZE_BPS) when no fees exist.
    function test_drip_revertsOnDust() public {
        vault.deposit(id, 0, 100e18, 100e18, 0);
        vm.warp(block.timestamp + FeraConstants.MEME_DRIP_MIN_INTERVAL_SEC + 1);
        vm.expectRevert(IFeraVault.DripTooSmall.selector);
        vault.drip(id, 0);
    }

    // ── access control ───────────────────────────────────────────────────────────────────────
    function test_createPool_onlyKeeper() public {
        vm.prank(makeAddr("notKeeper"));
        vm.expectRevert(IFeraVault.OnlyKeeper.selector);
        vault.createPool(poolKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, "x", "x");
    }

    function test_pauseDeposits_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(); // Ownable unauthorized
        vault.pauseDeposits(id);
    }

    function test_unknownTranche_reverts() public {
        vm.expectRevert(IFeraVault.UnknownTranche.selector);
        vault.deposit(id, 1, 1e18, 1e18, 0); // MEME has only tranche 0 (D-16)
    }
}
