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
import {IFeraShare} from "../../src/interfaces/IFeraShare.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {QW} from "../utils/QW.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
// NB: the INVERSE valuation helper (liquidity → amounts) lives in v4-core's test utils; the
// v4-periphery LiquidityAmounts only ships the forward direction (amounts → liquidity).
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title WithdrawQueueSolvency_PoC — proves the universal 24h async-redemption queue is SOLVENT
///        BY CONSTRUCTION and that every incident-control lever behaves.
/// @notice THE SOLVENCY MECHANISM UNDER TEST (escrow → settle-in-kind → burn):
///          1. `requestWithdraw` TRANSFERS the caller's shares into the vault's custody (escrow). They
///             are NOT burned and NO token amount is snapshotted, so they REMAIN in totalSupply and
///             the requester stays proportionally invested for the whole delay.
///          2. `claimWithdraw` pays `floor(currentHolding × escrowedShares / currentTotalSupply)` per
///             leg — a fraction of what ACTUALLY exists at claim time — reusing the exact pro-rata
///             primitive, so it can never remove more than its live share regardless of what happened
///             during the delay (fees, rebalances, price moves).
///          3. The escrowed shares are BURNED as the assets leave ⇒ totalSupply and holdings drop
///             together ⇒ pricePerShare-neutral (the OTHER holders are never diluted or shorted).
///        The stateful fuzz below rebalances / accrues fees / moves the price DURING the 24h and then
///        asserts (a) the claimant took ≤ its exact pro-rata of CURRENT holdings on BOTH legs,
///        (b) per-share backing never dropped (non-dilution + Σclaims ≤ holdings), and (c) the other
///        holder still exits whole.
contract WithdrawQueueSolvencyPoC is Deployers {
    using StateLibrary for IPoolManager;

    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;

    PoolKey internal key_;
    PoolId internal id;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal caller = makeAddr("thirdPartyCaller");

    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant COOLDOWN = 3_600;
    uint256 internal constant DELAY = 24 hours;

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
        address hookAddr = address(flags | (uint160(0x71E5) << 14));
        // keeper is the strategy keeper; this test contract is owner (timelock).
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), IAnchorStaking(address(0)), address(shareImpl), keeper, address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);

        key_ = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        id = vault.createBaseLimitPool(key_, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME", "M");
        vault.setWithdrawGuardian(guardian);

        _fund(alice, 1_000_000e18);
        _fund(bob, 1_000_000e18);
    }

    function _fund(address who, uint256 amt) internal {
        MockERC20(Currency.unwrap(currency0)).transfer(who, amt);
        MockERC20(Currency.unwrap(currency1)).transfer(who, amt);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _share() internal view returns (IFeraShare) {
        return IFeraShare(vault.shareToken(id, 0));
    }

    function _deposit(address who, uint256 a) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(id, 0, a, a, 0);
    }

    /// @dev The vault's CURRENT claimable holdings per leg (band principal at spot + pending + reserve),
    ///      measured AFTER a fee checkpoint so accrued fees are already in `pending` (matching claim).
    function _holdings(uint160 sp) internal view returns (uint256 h0, uint256 h1) {
        uint256 n = vault.bandCount(id, 0);
        for (uint256 i; i < n; ++i) {
            (int24 lo, int24 hi, uint128 liq,,) = vault.bandInfo(id, 0, i);
            if (liq == 0) continue;
            (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
                sp, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), liq
            );
            h0 += a0;
            h1 += a1;
        }
        (uint256 p0, uint256 p1) = vault.pendingFees(id, 0);
        (uint256 r0, uint256 r1) = vault.idleReserves(id, 0);
        h0 += p0 + r0;
        h1 += p1 + r1;
    }

    function _navT1(uint160 sp, uint256 h0, uint256 h1) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(uint256(sp), uint256(sp), 1 << 96);
        return FullMath.mulDiv(h0, priceX96, 1 << 96) + h1;
    }

    function extSwap(bool zeroForOne, int256 amt) external {
        swap(key_, zeroForOne, amt, "");
    }

    function _refresh() internal {
        try this.extSwap(true, -1e15) {} catch {}
        try this.extSwap(false, -1e15) {} catch {}
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // THE GATE — solvency under arbitrary intervening activity during the 24h delay.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Two holders; alice requests; the keeper rebalances / fees accrue / the price moves
    ///         during the 24h; then alice claims. Assert she gets EXACTLY her share-ratio of CURRENT
    ///         holdings on BOTH legs (never more — solvency; ~never less — not shorted), bob is never
    ///         diluted (per-share backing non-decreasing), and Σpayout ≤ holdings.
    function testFuzz_solvency_claimIsFairShareOfCurrentHoldings(
        uint256 aliceAmt,
        uint256 bobAmt,
        uint256 actSeed,
        uint256 swapSeed
    ) public {
        aliceAmt = bound(aliceAmt, 10e18, 200_000e18);
        bobAmt = bound(bobAmt, 10e18, 200_000e18);

        uint256 aShares = _deposit(alice, aliceAmt);
        uint256 bShares = _deposit(bob, bobAmt);
        assertGt(aShares, 0);
        assertGt(bShares, 0);

        // alice enters the queue (escrow). Her shares LEAVE her wallet but STAY in totalSupply.
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 supBefore = _share().totalSupply();
        uint256 reqId = QW.request(vault, id, 0, aShares, 0, 0, alice);
        assertEq(_share().balanceOf(alice), 0, "shares not escrowed");
        assertEq(_share().balanceOf(address(vault)), aShares, "vault did not custody escrow");
        assertEq(_share().totalSupply(), supBefore, "escrow must NOT change totalSupply (stays invested)");

        // ── intervening activity DURING the 24h delay: swaps (fees + price move) + keeper rebalances ──
        _churn(actSeed, swapSeed);

        // Mature the request — warp strictly past its STORED unlock (well past the JIT window too).
        // NB: read the stored unlockTime rather than `block.timestamp + DELAY`; under via_ir the
        // optimizer commons `block.timestamp` across the `vm.warp` cheatcode, which would undershoot
        // once a claim already advanced time earlier in the body (see QW.drain).
        (,,,, uint64 aUnlock,,,,,,,) = vault.withdrawRequests(reqId);
        vm.warp(uint256(aUnlock) + 1);

        // Realize fees into `pending` so the pre-claim holdings snapshot matches what the claim pays.
        vault.collectFees(id, 0);

        (uint160 sp,,,) = manager.getSlot0(id);
        (uint256 h0, uint256 h1) = _holdings(sp);
        uint256 vBefore = _navT1(sp, h0, h1);
        uint256 sBefore = _share().totalSupply(); // still includes alice's escrowed aShares

        // alice's EXACT pro-rata of CURRENT holdings, per leg (the claim floors per band, so actual ≤ this).
        uint256 fair0 = FullMath.mulDiv(h0, aShares, sBefore);
        uint256 fair1 = FullMath.mulDiv(h1, aShares, sBefore);

        // Dust bound: per-band + held flooring (all against the withdrawer) plus the wei-level gap
        // between LiquidityAmounts.getAmountsForLiquidity (used for `_holdings`) and v4's internal
        // removal math. Negligible vs the 1e18+ leg amounts — a real over-extraction bug would be a
        // PERCENTAGE of holdings, caught easily; the strong solvency proofs are (3) and Σ≤holdings.
        uint256 bandDust = 8 * (vault.bandCount(id, 0) + 4);

        (uint256 a0, uint256 a1) = vault.claimWithdraw(reqId);

        // (1) SOLVENCY (never over-extract): the claim removed ≤ alice's exact fair pro-rata on BOTH legs.
        assertLe(a0, fair0 + bandDust, "claim over-extracted token0 (INSOLVENT)");
        assertLe(a1, fair1 + bandDust, "claim over-extracted token1 (INSOLVENT)");
        // (2) NOT SHORTED: she got ~her fair share (only per-band + held flooring dust withheld).
        assertGe(a0 + bandDust, fair0, "claimant shorted token0");
        assertGe(a1 + bandDust, fair1, "claimant shorted token1");

        // (3) NON-DILUTION + SOLVENCY: per-share backing never dropped across the claim, and the burn
        //     kept it pricePerShare-neutral (can only round UP for stayers). Cross-multiplied to avoid
        //     division. vAfter/sAfter >= vBefore/sBefore.
        (uint160 sp2,,,) = manager.getSlot0(id);
        (uint256 g0, uint256 g1) = _holdings(sp2);
        uint256 vAfter = _navT1(sp2, g0, g1);
        uint256 sAfter = _share().totalSupply();
        assertEq(sAfter, sBefore - aShares, "burn must drop totalSupply by exactly the escrow");
        // pps non-decreasing (allow tiny slack for cross-term rounding on huge products).
        assertGe(vAfter * sBefore + (vBefore * sAfter) / 1e6 + 1, vBefore * sAfter, "bob was DILUTED by alice's claim");

        // (4) bob still exits whole — his value tracks the (never-decreased) per-share backing.
        uint256 bobVal0;
        uint256 bobVal1;
        {
            (uint256 bb0, uint256 bb1) = _bal(bob);
            QW.drain(vault, id, 0, bShares, 0, 0, bob);
            (uint256 ba0, uint256 ba1) = _bal(bob);
            bobVal0 = ba0 - bb0;
            bobVal1 = ba1 - bb1;
        }
        // Σpayout across BOTH holders ≤ the holdings that existed before alice claimed (per leg + dust):
        // nothing was minted from nothing.
        assertLe(a0 + bobVal0, h0 + bandDust, "sum-payout token0 exceeded holdings (INSOLVENT)");
        assertLe(a1 + bobVal1, h1 + bandDust, "sum-payout token1 exceeded holdings (INSOLVENT)");
    }

    function _bal(address who) internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(Currency.unwrap(currency0)).balanceOf(who);
        b1 = IERC20(Currency.unwrap(currency1)).balanceOf(who);
    }

    /// @dev Fuzzed intervening activity: real swaps (accrue dynamic fees + move spot) plus guarded
    ///      keeper rebalances (skimIdle / rebalanceLimit / selfSwap). Bounded so the pool survives.
    function _churn(uint256 actSeed, uint256 swapSeed) internal {
        uint256 nSwaps = 1 + (swapSeed % 4);
        for (uint256 i; i < nSwaps; ++i) {
            bool z = ((swapSeed >> (i + 1)) & 1) == 0;
            int256 amt = -int256(bound(uint256(keccak256(abi.encode(swapSeed, i))), 1e15, 500e18));
            try this.extSwap(z, amt) {} catch {}
        }
        if (actSeed & 1 != 0) {
            vm.prank(keeper);
            try vault.skimIdle(id, 0) {} catch {}
        }
        if (actSeed & 2 != 0) {
            vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
            _refresh();
            vm.prank(keeper);
            try vault.rebalanceLimit(id, 0) {} catch {}
        }
        if (actSeed & 4 != 0) {
            (uint256 r0, uint256 r1) = vault.idleReserves(id, 0);
            bool z = (actSeed & 8) == 0;
            uint256 a = (z ? r0 : r1) / 20;
            if (a != 0) {
                vm.prank(keeper);
                try vault.selfSwap(id, 0, z, a) {} catch {}
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // DELAY ENFORCEMENT + NO DOUBLE-SPEND
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_delayEnforced_claimBeforeUnlockReverts() public {
        uint256 sh = _deposit(alice, 1_000e18);
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 reqId = QW.request(vault, id, 0, sh, 0, 0, alice);

        // Just before maturity: reverts.
        vm.warp(block.timestamp + DELAY - 2);
        vm.expectRevert(IFeraVault.RequestNotMatured.selector);
        vault.claimWithdraw(reqId);

        // At maturity: settles.
        vm.warp(block.timestamp + 2);
        (uint256 a0, uint256 a1) = vault.claimWithdraw(reqId);
        assertGt(a0 + a1, 0, "matured claim paid nothing");
        // Second claim reverts (no double-settle).
        vm.expectRevert(IFeraVault.RequestSettled.selector);
        vault.claimWithdraw(reqId);
    }

    function test_noDoubleSpend_escrowedSharesCannotMoveOrRerequest() public {
        uint256 sh = _deposit(alice, 1_000e18);
        vm.warp(block.timestamp + COOLDOWN + 1);
        QW.request(vault, id, 0, sh, 0, 0, alice);

        // alice's wallet is now empty — she cannot transfer or re-request the escrowed shares.
        IFeraShare s = _share();
        assertEq(s.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(); // ERC20 balance underflow
        s.transfer(bob, sh);

        vm.prank(alice);
        s.approve(address(vault), sh);
        vm.prank(alice);
        vm.expectRevert(); // transferFrom of shares she no longer holds
        vault.requestWithdraw(id, 0, sh, 0, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // GUARDIAN FLAG / OWNER RESOLVE / CANCEL
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_flag_blocksClaim_guardianOnly() public {
        uint256 sh = _deposit(alice, 1_000e18);
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 reqId = QW.request(vault, id, 0, sh, 0, 0, alice);

        // Only the guardian may flag.
        vm.prank(bob);
        vm.expectRevert(IFeraVault.OnlyGuardian.selector);
        vault.flag(reqId);

        vm.prank(guardian);
        vault.flag(reqId);

        // A flagged, matured request cannot be claimed.
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(IFeraVault.RequestFlagged.selector);
        vault.claimWithdraw(reqId);
    }

    function test_resolveReturn_sharesBack_cannotClaim_ownerOnly() public {
        uint256 sh = _deposit(alice, 1_000e18);
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 reqId = QW.request(vault, id, 0, sh, 0, 0, alice);
        vm.prank(guardian);
        vault.flag(reqId);

        // Only the owner (timelock) may resolve.
        vm.prank(guardian);
        vm.expectRevert(); // Ownable unauthorized
        vault.resolveFlagged(reqId, false);

        // resolve(return): escrowed shares go BACK to alice, request voided.
        vault.resolveFlagged(reqId, false);
        assertEq(_share().balanceOf(alice), sh, "escrow not returned to owner");
        assertEq(_share().balanceOf(address(vault)), 0, "vault still holds escrow");

        // The voided request can never be claimed (no double-spend of the returned shares).
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(IFeraVault.RequestSettled.selector);
        vault.claimWithdraw(reqId);
    }

    function test_resolveRelease_claimProceeds() public {
        uint256 sh = _deposit(alice, 1_000e18);
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 reqId = QW.request(vault, id, 0, sh, 0, 0, alice);
        vm.prank(guardian);
        vault.flag(reqId);

        // release=true clears the flag; the matured claim then settles to alice.
        vault.resolveFlagged(reqId, true);
        vm.warp(block.timestamp + DELAY);
        (uint256 b0, uint256 b1) = _bal(alice);
        vault.claimWithdraw(reqId); // permissionless
        (uint256 a0, uint256 a1) = _bal(alice);
        assertGt((a0 - b0) + (a1 - b1), 0, "released claim paid nothing to owner");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // PERMISSIONLESS CLAIM PAYS THE REQUESTER + PAUSE FREEZES CLAIM
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_permissionlessClaim_paysRequesterNotCaller() public {
        uint256 sh = _deposit(alice, 1_000e18);
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 reqId = QW.request(vault, id, 0, sh, 0, 0, alice);
        vm.warp(block.timestamp + DELAY);

        (uint256 ca0, uint256 ca1) = _bal(caller);
        (uint256 aa0, uint256 aa1) = _bal(alice);
        // A random third party pushes the matured claim; the payout goes to ALICE, never the caller.
        vm.prank(caller);
        vault.claimWithdraw(reqId);
        assertEq(_bal0(caller) - ca0, 0, "third-party caller received token0");
        assertEq(_bal1(caller) - ca1, 0, "third-party caller received token1");
        assertGt((_bal0(alice) - aa0) + (_bal1(alice) - aa1), 0, "requester was not paid");
    }

    function _bal0(address w) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency0)).balanceOf(w);
    }

    function _bal1(address w) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency1)).balanceOf(w);
    }

    function test_pauseFreezesClaim() public {
        uint256 sh = _deposit(alice, 1_000e18);
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 reqId = QW.request(vault, id, 0, sh, 0, 0, alice);
        vm.warp(block.timestamp + DELAY);

        vault.pauseDeposits(id);
        vm.expectRevert(IFeraVault.ClaimsPaused.selector);
        vault.claimWithdraw(reqId);

        vault.unpauseDeposits(id);
        (uint256 a0, uint256 a1) = vault.claimWithdraw(reqId);
        assertGt(a0 + a1, 0, "claim blocked after unpause");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // ESCROWED SHARES REMAIN IN THE ERC-4626 READ SURFACE (no double/under-count)
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_readSurface_consistentWhileEscrowed() public {
        uint256 aShares = _deposit(alice, 1_000e18);
        _deposit(bob, 1_000e18);
        vm.warp(block.timestamp + COOLDOWN + 1);

        IFeraShare s = _share();
        uint256 supplyBefore = s.totalSupply();
        (uint160 sp,,,) = manager.getSlot0(id);
        (uint256 h0, uint256 h1) = _holdings(sp);
        uint256 navBefore = _navT1(sp, h0, h1);

        // Requesting only ESCROWS the shares — totalSupply AND the spot NAV are unchanged (alice stays
        // fully invested during the delay; the read surface must not double- or under-count the escrow,
        // and value-per-share = NAV / totalSupply is therefore unperturbed).
        uint256 reqId = QW.request(vault, id, 0, aShares, 0, 0, alice);
        assertEq(s.totalSupply(), supplyBefore, "escrow changed totalSupply");
        assertEq(s.balanceOf(address(vault)), aShares, "vault custody != escrow");
        (uint160 sp2,,,) = manager.getSlot0(id);
        (uint256 g0, uint256 g1) = _holdings(sp2);
        assertEq(_navT1(sp2, g0, g1), navBefore, "escrow changed the vault NAV");

        // The burn happens exactly at claim: totalSupply drops by exactly the escrow (pricePerShare-neutral).
        vm.warp(block.timestamp + DELAY);
        vault.claimWithdraw(reqId);
        assertEq(s.totalSupply(), supplyBefore - aShares, "burn-on-claim must drop supply by exactly the escrow");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // CANCEL — anti-trap recourse returns the escrow, no double-spend
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_cancelWithdraw_returnsShares_noDoubleSpend() public {
        uint256 sh = _deposit(alice, 1_000e18);
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 reqId = QW.request(vault, id, 0, sh, 0, 0, alice);
        assertEq(_share().balanceOf(alice), 0);

        // Only the owner of the request can cancel it.
        vm.prank(bob);
        vm.expectRevert(IFeraVault.NotRequestOwner.selector);
        vault.cancelWithdraw(reqId);

        // Cancel returns the ESCROWED shares to alice and voids the request.
        vm.prank(alice);
        vault.cancelWithdraw(reqId);
        assertEq(_share().balanceOf(alice), sh, "cancel did not return escrow");

        // A canceled request can never be claimed OR re-canceled (no double-spend).
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(IFeraVault.RequestSettled.selector);
        vault.claimWithdraw(reqId);
        vm.prank(alice);
        vm.expectRevert(IFeraVault.RequestSettled.selector);
        vault.cancelWithdraw(reqId);

        // A guardian-flagged request cannot be self-canceled (guardian freeze respected).
        IFeraShare s = _share();
        vm.prank(alice);
        s.approve(address(vault), sh);
        vm.prank(alice);
        uint256 reqId2 = vault.requestWithdraw(id, 0, sh, 0, 0);
        vm.prank(guardian);
        vault.flag(reqId2);
        vm.prank(alice);
        vm.expectRevert(IFeraVault.RequestFlagged.selector);
        vault.cancelWithdraw(reqId2);
    }
}
