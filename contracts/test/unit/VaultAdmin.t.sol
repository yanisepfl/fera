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
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Coverage for the Vault admin surface + the on-chain market-hours gate branches the
///         lifecycle/strategy suites don't reach: schedule-bitmap gating (holiday / keeper-flag /
///         168-bit calendar), event-window q-raise (0.80), keeper rotation + zero-check, the bounded
///         TWAP-gate setter, the launchpad guard, and the read-only getters. INV-11/INV-12 admin set.
contract VaultAdminTest is Deployers {
    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;
    MockAggregatorV3 internal feed;

    PoolKey internal memeKey;
    PoolKey internal rwaKey;
    PoolId internal memeId;
    PoolId internal rwaId;

    uint256 internal constant T0 = 10_000_000;
    address internal keeper2 = makeAddr("keeper2");
    address internal notOwner = makeAddr("notOwner");

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
        address hookAddr = address(flags | (uint160(0xAD31) << 14));
        // keeper == owner == this test contract.
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

        memeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        rwaKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hookAddr));
        // v3.3 permissionless creation: team-curation levers must be set before pool creation.
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        vault.approveRwaFeed(address(feed), "test RWA feed");
        memeId = vault.createBaseLimitPool(memeKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME-LP", "mLP");
        rwaId = vault.createBaseLimitPool(rwaKey, FeraTypes.Regime.RWA, address(feed), SQRT_PRICE_1_1, true, "NVDA-LP", "nLP");

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
    }

    function _hourBit(uint256 hourOfWeek) internal pure returns (uint256) {
        return uint256(1) << hourOfWeek;
    }

    function _nowHour() internal view returns (uint256) {
        return (block.timestamp / 3_600) % 168;
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // Market-hours gate — holiday / keeper-flag / on-chain 168-bit calendar (all three legs).
    // MEME is "always open" (keeper flag set at createPool, no calendar) — the back-compat leg.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_marketHours_memeAlwaysOpen_noCalendar() public view {
        // MEME is "always open" on the Vault (keeper flag set at createPool, no calendar). The hook's
        // market-hours gate is only consulted on the RWA fee overlay, so its MEME value is unused.
        assertTrue(vault.isMarketOpen(memeId), "MEME should default open (keeper flag, no calendar)");
    }

    function test_marketHours_rwaKeeperFlagGovernsWithoutCalendar() public {
        // RWA starts closed (marketOpen=false at createPool). Keeper flag alone (no calendar) governs.
        assertFalse(vault.isMarketOpen(rwaId), "RWA should start closed");
        vault.setMarketOpen(rwaId, true);
        assertTrue(vault.isMarketOpen(rwaId), "keeper-open (no calendar) should open");
        assertTrue(hook.isMarketOpen(rwaId), "hook mirror not opened");
    }

    function test_marketHours_calendarBoundsKeeper() public {
        vault.setMarketOpen(rwaId, true); // keeper says open
        uint256 h = _nowHour();

        // Calendar with the CURRENT hour bit SET ⇒ open (schedule AND flag agree).
        vault.setSchedule(rwaId, _hourBit(h));
        assertTrue(vault.isMarketOpen(rwaId), "calendar-open hour should be open");
        assertTrue(hook.isMarketOpen(rwaId), "hook calendar mirror disagrees (open)");

        // Calendar with the current hour bit CLEARED (some OTHER hour set) ⇒ closed even with keeper open.
        uint256 other = (h + 1) % 168;
        vault.setSchedule(rwaId, _hourBit(other));
        assertFalse(vault.isMarketOpen(rwaId), "calendar bounds the keeper: out-of-hours must be closed");
        assertFalse(hook.isMarketOpen(rwaId), "hook calendar mirror disagrees (closed)");
    }

    function test_marketHours_holidayForceCloses() public {
        vault.setMarketOpen(rwaId, true);
        assertTrue(vault.isMarketOpen(rwaId), "should be open pre-holiday");
        vault.setHoliday(rwaId, true); // keeper holiday flag — force close
        assertFalse(vault.isMarketOpen(rwaId), "holiday must force-close");
        assertFalse(hook.isMarketOpen(rwaId), "hook holiday mirror did not force-close");
        vault.setHoliday(rwaId, false);
        assertTrue(vault.isMarketOpen(rwaId), "clearing holiday should reopen");
    }

    function test_setSchedule_unknownPoolReverts() public {
        PoolKey memory k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 100, IHooks(address(hook)));
        vm.expectRevert(IFeraVault.UnknownPool.selector);
        vault.setSchedule(k.toId(), 1);
    }

    function test_setSchedule_onlyOwner() public {
        vm.prank(notOwner);
        vm.expectRevert();
        vault.setSchedule(rwaId, 1);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // Event window — D-M11 keeper flag. v3: no on-chain consumer (the legacy RWA partial-withdraw
    // cap it raised is removed); the flag + its view are kept as reserved keeper-signal state.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_eventWindow_flagToggles() public {
        assertFalse(vault.isEventWindow(rwaId), "event window should default off");
        vault.setEventWindow(rwaId, true);
        assertTrue(vault.isEventWindow(rwaId), "event window flag not set");
        vault.setEventWindow(rwaId, false);
        assertFalse(vault.isEventWindow(rwaId), "event window flag did not clear");
    }

    function test_setEventWindow_onlyKeeper() public {
        vm.prank(notOwner);
        vm.expectRevert(IFeraVault.OnlyKeeper.selector);
        vault.setEventWindow(rwaId, true);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // Keeper rotation — owner-only, zero-address rejected (hardening), rotated keeper is authoritative.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_setKeeper_rotates_and_gates() public {
        vault.setKeeper(keeper2);
        assertEq(vault.keeper(), keeper2, "keeper not rotated");

        // The OLD keeper (this test) can no longer run keeper actions.
        vm.expectRevert(IFeraVault.OnlyKeeper.selector);
        vault.setMarketOpen(rwaId, true);

        // The new keeper can.
        vm.prank(keeper2);
        vault.setMarketOpen(rwaId, true);
        assertTrue(vault.isMarketOpen(rwaId), "rotated keeper action did not take effect");
    }

    function test_setKeeper_onlyOwner() public {
        vm.prank(notOwner);
        vm.expectRevert();
        vault.setKeeper(keeper2);
    }

    function test_setKeeper_zeroAddressRejected() public {
        vm.expectRevert(IFeraVault.ZeroAddress.selector);
        vault.setKeeper(address(0));
    }

    function test_constructor_zeroAddressRejected() public {
        // keeper_ == 0 and shareImplementation_ == 0 both trip the guard (`||` legs).
        vm.expectRevert(IFeraVault.ZeroAddress.selector);
        new FeraVault(
            manager,
            IFeraHook(address(hook)),
            IRevenueDistributor(address(rev)),
            IAnchorStaking(address(0)),
            address(shareImpl),
            address(0),
            address(this)
        );
        vm.expectRevert(IFeraVault.ZeroAddress.selector);
        new FeraVault(
            manager,
            IFeraHook(address(hook)),
            IRevenueDistributor(address(rev)),
            IAnchorStaking(address(0)),
            address(0),
            address(this),
            address(this)
        );
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // Bounded TWAP-gate setter — owner may move WITHIN [50,500]bp; the bounds are immutable (Gamma).
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_setDepositTwapGate_withinBounds() public {
        vault.setDepositTwapGate(FeraConstants.DEPOSIT_TWAP_GATE_MIN_BPS);
        assertEq(vault.depositTwapGateBps(), FeraConstants.DEPOSIT_TWAP_GATE_MIN_BPS, "gate not set to floor");
        vault.setDepositTwapGate(FeraConstants.DEPOSIT_TWAP_GATE_MAX_BPS);
        assertEq(vault.depositTwapGateBps(), FeraConstants.DEPOSIT_TWAP_GATE_MAX_BPS, "gate not set to ceiling");
    }

    function test_setDepositTwapGate_belowFloorReverts() public {
        vm.expectRevert(IFeraVault.GateOutOfBounds.selector);
        vault.setDepositTwapGate(FeraConstants.DEPOSIT_TWAP_GATE_MIN_BPS - 1);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // Launchpad class — present in the type system, disabled in v1 (D-1/§4): always reverts.
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_enableLaunchpad_disabledInV1() public {
        vm.expectRevert(IFeraVault.LaunchpadDisabled.selector);
        vault.enableLaunchpad(memeId);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // Read-only getters — view coverage (base+limit+idle shape: 2 tranches, 1 base band each).
    // ══════════════════════════════════════════════════════════════════════════════════════
    function test_views_defaults() public view {
        assertEq(vault.trancheCount(memeId), 2, "MEME tranche count (Steady+Active)");
        assertEq(vault.trancheCount(rwaId), 2, "RWA tranche count (Steady+Active)");
        assertEq(uint8(vault.regimeOf(memeId)), uint8(FeraTypes.Regime.MEME), "MEME regime");
        assertEq(uint8(vault.regimeOf(rwaId)), uint8(FeraTypes.Regime.RWA), "RWA regime");
        assertFalse(vault.depositsPaused(memeId), "should not be paused");
        (uint256 p0, uint256 p1) = vault.pendingFees(memeId, 0);
        assertEq(p0 + p1, 0, "no pending fees at genesis");
        assertTrue(vault.shareToken(memeId, 0) != address(0), "share token unset");
        assertEq(vault.bandCount(memeId, 0), 1, "one base band at genesis");
    }

    function test_pauseUnpause_deposits() public {
        vault.pauseDeposits(memeId);
        assertTrue(vault.depositsPaused(memeId), "pause did not take");
        vm.expectRevert(IFeraVault.DepositsPaused.selector);
        vault.deposit(memeId, 0, 1e18, 1e18, 0);
        vault.unpauseDeposits(memeId);
        assertFalse(vault.depositsPaused(memeId), "unpause did not take");
    }

    /// @notice Pause posture (pause hardening): a pool pause freezes DEPOSITS *and every*
    ///         position-moving strategy action (rebalance / skim / self-swap), but NEVER withdrawal —
    ///         funds are never trapped. Deposit-only pause was too weak: a mid-incident rebalance or
    ///         swap path could still fire. Withdrawal stays unblockable so users can always exit.
    function test_pauseFreezesStrategy_butNeverWithdrawals() public {
        vault.deposit(memeId, 0, 100e18, 100e18, 0);
        uint256 sh = FeraShare(vault.shareToken(memeId, 0)).balanceOf(address(this));
        assertGt(sh, 0, "no shares minted");

        vault.pauseDeposits(memeId);

        // Every position-moving strategy action is frozen while paused (notPaused gate).
        vm.expectRevert(IFeraVault.DepositsPaused.selector);
        vault.rebalanceLimit(memeId, 0);
        vm.expectRevert(IFeraVault.DepositsPaused.selector);
        vault.rebalanceBase(memeId, 0, false);
        vm.expectRevert(IFeraVault.DepositsPaused.selector);
        vault.skimIdle(memeId, 0);
        vm.expectRevert(IFeraVault.DepositsPaused.selector);
        vault.selfSwap(memeId, 0, true, 1e18);

        // ...but withdrawal ALWAYS works — a pause can never trap funds. (Warp past the 1h
        // DEPOSIT_COOLDOWN_SEC Veda share-lock, which is an anti-JIT guard unrelated to pause — its
        // presence here, rather than DepositsPaused, is itself proof withdraw is NOT pause-gated.)
        vm.warp(block.timestamp + 3_601);
        vault.withdraw(memeId, 0, sh, 0, 0);
        assertEq(FeraShare(vault.shareToken(memeId, 0)).balanceOf(address(this)), 0, "shares not burned on withdraw");
    }

    /// @notice ERC-4626-style quote pricing (for DefiLlama / Rabby): the vault exposes a TWAP-priced,
    ///         quote-denominated NAV, and each share reports asset()/totalAssets()/convertToAssets()/
    ///         pricePerShare() consistently off it.
    function test_quoteNav_and_erc4626PricingSurface() public {
        vault.deposit(memeId, 0, 100e18, 100e18, 0);
        vm.warp(block.timestamp + 601); // past DEPOSIT_TWAP_WINDOW_SEC (600); pre-window falls back to spot

        uint256 nav = vault.quoteNav(memeId, 0);
        assertGt(nav, 0, "quoteNav should be positive after a deposit");

        FeraShare share = FeraShare(vault.shareToken(memeId, 0));
        address quote = vault.quoteAsset(memeId);
        assertTrue(
            quote == Currency.unwrap(currency0) || quote == Currency.unwrap(currency1), "quoteAsset not a pool token"
        );
        assertEq(share.asset(), quote, "share.asset() != vault.quoteAsset");
        assertEq(share.totalAssets(), nav, "share.totalAssets() != quoteNav");

        uint256 supply = share.totalSupply();
        uint256 myShares = share.balanceOf(address(this));
        assertGt(myShares, 0, "no shares");
        assertApproxEqAbs(share.convertToAssets(supply), nav, 2, "convertToAssets(totalSupply) != NAV");
        assertEq(share.pricePerShare(), share.convertToAssets(1e18), "pricePerShare != convertToAssets(1e18)");
        assertApproxEqAbs(share.convertToAssets(myShares), nav * myShares / supply, 2, "share value not pro-rata");
    }
}
