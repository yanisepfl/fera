// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FeraVault} from "../../src/FeraVault.sol";
import {FeraHook} from "../../src/FeraHook.sol";
import {FeraShare} from "../../src/shares/FeraShare.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice INV-4 — UNBOUNDED stateful invariant campaign. Supersedes the skipped
///         `test/stubs/PendingInvariants.t.sol::test_INV4_sharePriceMonotone_TODO` with a real
///         `StdInvariant` handler campaign (foundry.toml `[invariant]` = 256 runs x 64 depth ≈ 16k
///         randomized calls per run). The fuzzer drives arbitrary-length, arbitrary-order sequences of
///         deposit / withdraw / external-swap / skimIdle / rebalanceLimit / rebalanceBase / selfSwap /
///         warp against BOTH tranches, and asserts:
///
///           (INV-4a) NO SINGLE STRATEGY ACTION reduces a tranche's NAV-per-share beyond the protocol's
///                    OWN per-recenter IL bound (`MAX_IL_BPS_PER_RECENTER` = 300bps) + a small margin for
///                    self-swap slippage / wei rounding. A larger single-action drop IS a real dilution.
///           (INV-4b) CUMULATIVE NAV-per-share never collapses (gross compounding dilution) nor explodes
///                    (value minted from nothing) relative to the seeded baseline.
///
///         Design (mirrors BaseLimitNavInvariant): the refHolder seeds BOTH tranches with dominant,
///         price-pinning liquidity, so the pool spot stays ~1:1 and the vault's own `quoteNav` (TWAP-
///         priced, base+limit+pending+idle) is a faithful NAV measure. Strategy actions are wrapped so
///         NAV-per-share is snapshotted immediately before/after in the SAME block (constant price), which
///         isolates the action's value impact. Guarded (try/catch) throughout — `fail_on_revert = false`.
contract StrategyNavInvariantCampaign is Deployers {
    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;

    PoolKey internal blKey;
    PoolId internal blId;

    address internal refHolder = makeAddr("refHolder");
    address[2] internal foreign;

    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant COOLDOWN = 3_600;
    uint256 internal constant SEED = 500_000e18; // dominant, spot-pinning refHolder liquidity per tranche

    // INV-4a ceiling: the protocol caps a single recenter's realized IL at MAX_IL_BPS_PER_RECENTER; the
    // +50bps absorbs the tiny self-swap slippage + last-wei rounding. A single action over this is a bug.
    uint256 internal constant MAX_DROP_BPS = FeraConstants.MAX_IL_BPS_PER_RECENTER + 50; // 350bps

    // ghosts (only ever grow / are read by invariants)
    uint256 public worstDropBps;
    uint256 internal initNav0;
    uint256 internal initNav1;

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0xC4C4) << 14));
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), IAnchorStaking(address(0)), address(shareImpl), address(this), address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);

        blKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        blId = vault.createBaseLimitPool(blKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME-BL", "mBL");

        _fund(refHolder, 2_100_000e18);
        foreign[0] = makeAddr("foreignA");
        foreign[1] = makeAddr("foreignB");
        _fund(foreign[0], 400_000e18);
        _fund(foreign[1], 400_000e18);

        vm.prank(refHolder);
        vault.deposit(blId, 0, SEED, SEED, 0);
        vm.prank(refHolder);
        vault.deposit(blId, 1, SEED, SEED, 0);
        vm.warp(block.timestamp + COOLDOWN + FeraConstants.JIT_PENALTY_WINDOW_MEME + 1);
        _refresh();

        (initNav0,) = _navPerShareWad(0);
        (initNav1,) = _navPerShareWad(1);

        // Fuzz ONLY the guarded handler actions on this contract (so the fuzzer never bypasses the
        // measured wrappers by calling the vault/hook directly).
        bytes4[] memory sel = new bytes4[](8);
        sel[0] = this.hDeposit.selector;
        sel[1] = this.hWithdraw.selector;
        sel[2] = this.hSwap.selector;
        sel[3] = this.hSkim.selector;
        sel[4] = this.hRebalanceLimit.selector;
        sel[5] = this.hRebalanceBase.selector;
        sel[6] = this.hSelfSwap.selector;
        sel[7] = this.hWarp.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────────────────
    function _fund(address who, uint256 amt) internal {
        MockERC20(Currency.unwrap(currency0)).transfer(who, amt);
        MockERC20(Currency.unwrap(currency1)).transfer(who, amt);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Tiny net-zero swap pair to keep the TWAP head fresh so `quoteNav` never fail-closes (REC-9).
    function _refresh() internal {
        try this.extSwap(true, -1e14) {} catch {}
        try this.extSwap(false, -1e14) {} catch {}
    }

    function extSwap(bool z, int256 a) external {
        swap(blKey, z, a, "");
    }

    /// @dev Tranche NAV-per-share (WAD), from the vault's OWN quoteNav. `ok=false` if supply is 0 or the
    ///      TWAP is momentarily stale (skip the measurement rather than spuriously fail an invariant).
    function _navPerShareWad(uint8 t) internal returns (uint256 nav, bool ok) {
        uint256 ts = IERC20(vault.shareToken(blId, t)).totalSupply();
        if (ts == 0) return (0, false);
        try vault.quoteNav(blId, t) returns (uint256 q) {
            return (q * 1e18 / ts, true);
        } catch {
            return (0, false);
        }
    }

    function _measure(uint8 t, uint256 before, bool okb) internal {
        if (!okb || before == 0) return;
        (uint256 aft, bool oka) = _navPerShareWad(t);
        if (oka && aft < before) {
            uint256 d = (before - aft) * 10_000 / before;
            if (d > worstDropBps) worstDropBps = d;
        }
    }

    // ── handler actions (the fuzz target) ───────────────────────────────────────────────────────
    function hDeposit(uint256 s) external {
        uint8 t = uint8(s & 1);
        address a = foreign[(s >> 8) & 1];
        uint256 amt = bound(s >> 24, 1e18, 200e18); // « the dominant refHolder base ⇒ spot stays ~1:1
        vm.prank(a);
        try vault.deposit(blId, t, amt, amt, 0) {} catch {}
    }

    function hWithdraw(uint256 s) external {
        uint8 t = uint8(s & 1);
        address a = foreign[(s >> 8) & 1];
        vm.warp(block.timestamp + COOLDOWN + 1);
        _refresh();
        uint256 bal = IERC20(vault.shareToken(blId, t)).balanceOf(a);
        if (bal != 0) {
            vm.prank(a);
            try vault.withdraw(blId, t, bal, 0, 0) {} catch {}
        }
    }

    function hSwap(uint256 s) external {
        bool z = (s & 1) == 0;
        int256 amt = -int256(bound(s >> 8, 1e15, 800e18)); // bounded ⇒ dominant liquidity keeps spot ~1:1
        try this.extSwap(z, amt) {} catch {}
    }

    function hSkim(uint256 s) external {
        uint8 t = uint8(s & 1);
        _refresh();
        (uint256 b, bool okb) = _navPerShareWad(t);
        try vault.skimIdle(blId, t) {
            _measure(t, b, okb);
        } catch {}
    }

    function hRebalanceLimit(uint256 s) external {
        uint8 t = uint8(s & 1);
        vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
        _refresh();
        (uint256 b, bool okb) = _navPerShareWad(t);
        try vault.rebalanceLimit(blId, t) {
            _measure(t, b, okb);
        } catch {}
    }

    function hRebalanceBase(uint256 s) external {
        uint8 t = uint8(s & 1);
        vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
        _refresh();
        vault.pokeOutOfRange(blId, t);
        (uint256 b, bool okb) = _navPerShareWad(t);
        try vault.rebalanceBase(blId, t, (s & 2) == 0) {
            _measure(t, b, okb);
        } catch {}
    }

    function hSelfSwap(uint256 s) external {
        uint8 t = uint8(s & 1);
        vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
        _refresh();
        (uint256 r0, uint256 r1) = vault.idleReserves(blId, t);
        bool z = (s & 2) == 0;
        uint256 a = (z ? r0 : r1) / 200; // tiny ⇒ value impact stays internal
        if (a != 0) {
            (uint256 b, bool okb) = _navPerShareWad(t);
            try vault.selfSwap(blId, t, z, a) {
                _measure(t, b, okb);
            } catch {}
        }
    }

    function hWarp(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 1, 1_200));
        _refresh();
    }

    // ── invariants ──────────────────────────────────────────────────────────────────────────────
    /// INV-4a: across every randomized sequence, no single strategy action dilutes a tranche's NAV-per-
    ///         share beyond the protocol's own IL/slippage bound.
    function invariant_INV4_strategyActionNeverDilutes() public view {
        assertLe(worstDropBps, MAX_DROP_BPS, "INV-4: a strategy action diluted share value beyond the IL/slippage bound");
    }

    /// INV-4b: cumulative NAV-per-share never collapses (compounding dilution) nor explodes (value minted
    ///         from nothing) relative to the seeded baseline.
    function invariant_INV4_navPerShareBounded() public {
        for (uint8 t; t < 2; ++t) {
            (uint256 nav, bool ok) = _navPerShareWad(t);
            if (!ok) continue;
            uint256 init = t == 0 ? initNav0 : initNav1;
            if (init == 0) continue;
            assertGe(nav, init * 9_000 / 10_000, "INV-4: cumulative NAV/share collapse");
            assertLe(nav, init * 100, "INV-4: NAV/share exploded (value minted from nothing)");
        }
    }
}
