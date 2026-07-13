// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AnchorStaking} from "../../src/AnchorStaking.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {FeraToken} from "../../src/FeraToken.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MintableERC20, ReturnsFalseERC20} from "../utils/Mocks.sol";

/// @notice R-21 (skill-audit HIGH) regression — AnchorStaking reward-debt not settled on stake/unstake.
///
///   ROOT CAUSE (pre-fix): `stake`/`unstake` mutated `stakedOf`/`totalStaked` WITHOUT settling the
///   MasterChef accumulator, so `_rewardDebt` stayed stale. A late staker had `rewardDebt == 0` while
///   `accPerShare > 0` and could `claimRevenueShare` for `shares·accPerShare` — draining prior
///   stakers' accrued revenue. Reverse: an unstaker underflowed `accrued − rewardDebt` → revert.
///
///   FIX: standard MasterChef — every stake/unstake harvests all registered reward tokens FIRST
///        (on the OLD totalStaked, so pre-stake revenue is credited to existing stakers), settles the
///        caller's pending into `_claimable`, then re-bases `rewardDebt = newShares·accPerShare/PREC`.
///
///   These tests FAIL before the fix and PASS after it.
contract StakingRewardDebtPoCTest is Test {
    FeraToken internal fera;
    RevenueDistributor internal rev;
    AnchorStaking internal staking;
    MintableERC20 internal usd;

    address internal treasury = makeAddr("treasury");
    address internal ops = makeAddr("ops");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        fera = new FeraToken(address(this)); // genesis 1e26 FERA to this contract
        usd = new MintableERC20("USD", "USD");

        // Break the AnchorStaking↔RevenueDistributor cycle: predict staking's address so the
        // distributor's `stakers` recipient == the staking contract (it pulls the 50% share).
        address predictedStaking = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rev = new RevenueDistributor(predictedStaking, treasury, ops);
        // admin = this test contract (governance) so we can curate the reward-token allowlist.
        staking = new AnchorStaking(IERC20(address(fera)), IRevenueDistributor(address(rev)), address(this));
        require(address(staking) == predictedStaking, "staking addr mismatch");

        // Governance allowlists USD as a reward token at config time (REC-6/REC-7).
        staking.addRewardToken(address(usd));

        // Seed stakers with FERA and approvals.
        for (uint256 i; i < 3; ++i) {
            address who = [alice, bob, carol][i];
            IERC20(address(fera)).transfer(who, 1_000e18);
            vm.prank(who);
            IERC20(address(fera)).approve(address(staking), type(uint256).max);
        }
    }

    /// @dev Send `amount` USD of revenue into the distributor so stakers get their 50% share.
    function _sendStakerRevenue(uint256 stakerShare) internal {
        uint256 notify = stakerShare * 2; // 50% split ⇒ notify 2× to give stakers `stakerShare`
        usd.mint(address(rev), notify);
        rev.notifyRevenue(address(usd), notify);
        assertEq(rev.pending(address(staking), address(usd)), stakerShare, "staker pending mismatch");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 1. THE EXPLOIT: a late staker cannot claim revenue that accrued before they staked.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_R21_lateStaker_cannotClaimPriorRevenue() public {
        vm.prank(alice);
        staking.stake(100e18, 0);

        // Tranche 1: 50 USD to stakers. Alice harvests+claims it (registers USD, accPerShare = 0.5).
        _sendStakerRevenue(50e18);
        vm.prank(alice);
        assertEq(staking.claimRevenueShare(address(usd)), 50e18, "alice tranche-1");

        // Tranche 2: another 50 USD to stakers — sits UNHARVESTED in the distributor.
        _sendStakerRevenue(50e18);

        // Bob stakes AFTER accPerShare > 0. His stake harvests tranche-2 to Alice (old totalStaked)
        // and re-bases his rewardDebt, so he is entitled to ZERO of the pre-stake revenue.
        vm.prank(bob);
        staking.stake(100e18, 0);

        // EXPLOIT ASSERTION: pre-fix Bob drained ~75 here; post-fix he gets exactly 0.
        vm.prank(bob);
        assertEq(staking.claimRevenueShare(address(usd)), 0, "R-21: late staker stole prior revenue");

        // Alice still gets her full tranche-2 (nothing was stolen from her).
        vm.prank(alice);
        assertEq(staking.claimRevenueShare(address(usd)), 50e18, "alice tranche-2 shorted");

        // Conservation: total USD paid to stakers ≤ total staker-revenue (100).
        assertLe(usd.balanceOf(alice) + usd.balanceOf(bob), 100e18, "over-distribution");
        assertEq(usd.balanceOf(alice) + usd.balanceOf(bob), 100e18, "revenue not fully conserved");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 2. Post-join revenue splits pro-rata to the shares that existed WHEN it accrued.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_R21_postJoinRevenue_prorata() public {
        vm.prank(alice);
        staking.stake(100e18, 0);
        vm.prank(bob);
        staking.stake(300e18, 0); // Alice:Bob = 1:3 from here on

        _sendStakerRevenue(100e18); // 100 USD to stakers, both staked the whole time
        vm.prank(alice);
        uint256 a = staking.claimRevenueShare(address(usd));
        vm.prank(bob);
        uint256 b = staking.claimRevenueShare(address(usd));

        assertEq(a, 25e18, "alice != 1/4");
        assertEq(b, 75e18, "bob != 3/4");
        assertLe(a + b, 100e18, "over-distribution");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 3. Unstake settles first: an unstaker keeps their accrual and never underflow-reverts.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_R21_unstakeSettles_noUnderflowRevert() public {
        vm.prank(alice);
        staking.stake(100e18, 0);
        _sendStakerRevenue(40e18); // 40 USD to stakers

        // Register + accrue by claiming once (accPerShare = 0.4).
        vm.prank(alice);
        assertEq(staking.claimRevenueShare(address(usd)), 40e18, "alice initial claim");

        _sendStakerRevenue(40e18); // another 40, unharvested

        // Alice unstakes fully. Pre-fix this left rewardDebt stale; a later claim would underflow.
        // Post-fix the unstake harvests+settles her the pending 40 into _claimable.
        vm.prank(alice);
        staking.unstake(100e18); // must NOT revert

        vm.prank(alice);
        uint256 got = staking.claimRevenueShare(address(usd)); // must NOT revert
        assertEq(got, 40e18, "unstaker lost settled revenue");
        assertLe(usd.balanceOf(alice), 80e18, "over-distribution");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 4. Per-staker conservation (fuzz): Σ claims ≤ Σ staker-revenue, no staker over-claims.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function testFuzz_R21_conservation(uint256 aStake, uint256 bStake, uint256 rev1, uint256 rev2) public {
        aStake = bound(aStake, 1e18, 500e18);
        bStake = bound(bStake, 1e18, 500e18);
        rev1 = bound(rev1, 1e18, 400e18);
        rev2 = bound(rev2, 1e18, 400e18);

        vm.prank(alice);
        staking.stake(aStake, 0);

        _sendStakerRevenue(rev1); // accrues to Alice only
        vm.prank(alice);
        staking.claimRevenueShare(address(usd)); // registers USD, harvests rev1 to Alice

        vm.prank(bob);
        staking.stake(bStake, 0); // Bob joins; his stake harvests nothing new (rev1 already taken)

        _sendStakerRevenue(rev2); // accrues to Alice:Bob pro-rata

        vm.prank(alice);
        staking.claimRevenueShare(address(usd));
        vm.prank(bob);
        staking.claimRevenueShare(address(usd));

        uint256 totalRevenue = rev1 + rev2;
        uint256 totalPaid = usd.balanceOf(alice) + usd.balanceOf(bob);
        assertLe(totalPaid, totalRevenue, "paid more than staker revenue exists");
        // Bob can never receive more than his fair share of rev2 (he missed rev1 entirely).
        uint256 bobMax = (rev2 * bStake) / (aStake + bStake) + 1;
        assertLe(usd.balanceOf(bob), bobMax, "bob over-claimed (stole rev1)");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 5. REC-6 (allowlist register-at-config): an allowlisted token whose staker-revenue was credited
    //    but NEVER harvested is already in the auto-settle set, so a stake before its first harvest
    //    cannot dilute it. (USD is allowlisted in setUp — register-at-config = the safe equivalent of
    //    register-at-notify.)
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_REC6_allowlistedToken_notDilutedByLaterStake() public {
        vm.prank(alice);
        staking.stake(100e18, 0);

        // Revenue for USD credited to stakers, but NOBODY harvests/claims it.
        _sendStakerRevenue(50e18);
        assertTrue(staking.isRewardToken(address(usd)), "REC-6: token not on allowlist");

        // Bob stakes BEFORE USD's first harvest. Because USD is allowlisted, his stake harvests the
        // pending 50 to Alice (the OLD totalStaked) and re-bases his debt ⇒ he is owed 0 of it.
        vm.prank(bob);
        staking.stake(100e18, 0);

        vm.prank(bob);
        assertEq(staking.claimRevenueShare(address(usd)), 0, "REC-6: late staker diluted unharvested token");
        vm.prank(alice);
        assertEq(staking.claimRevenueShare(address(usd)), 50e18, "REC-6: alice shorted");
        assertEq(usd.balanceOf(alice) + usd.balanceOf(bob), 50e18, "REC-6: conservation");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 6. REC-7 (bounded, admin-only allowlist): the set is hard-capped at MAX_REWARD_TOKENS and only
    //    the reward admin may add — no permissionless path, no crowd-out.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_REC7_allowlist_cappedAndAdminOnly() public {
        address weth = makeAddr("weth");

        // Non-admin cannot add.
        vm.prank(alice);
        vm.expectRevert(IAnchorStaking.NotRewardAdmin.selector);
        staking.addRewardToken(weth);

        // Zero address / duplicate rejected (caller is admin = this test contract).
        vm.expectRevert(IAnchorStaking.InvalidRewardToken.selector);
        staking.addRewardToken(address(0));
        vm.expectRevert(IAnchorStaking.InvalidRewardToken.selector);
        staking.addRewardToken(address(usd)); // already added in setUp

        // Admin fills to exactly the cap (USD counts as 1).
        uint256 cap = staking.MAX_REWARD_TOKENS();
        while (staking.rewardTokenCount() < cap) {
            staking.addRewardToken(address(new MintableERC20("T", "T")));
        }
        assertEq(staking.rewardTokenCount(), cap, "did not fill to cap");

        // One past the cap reverts (deploy token FIRST so the CREATE is not attributed to expectRevert).
        address over = address(new MintableERC20("X", "X"));
        vm.expectRevert(IAnchorStaking.TooManyRewardTokens.selector);
        staking.addRewardToken(over);

        // Stake/unstake still work over the full (capped) loop.
        vm.prank(alice);
        staking.stake(100e18, 0);
        vm.prank(alice);
        staking.unstake(100e18);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 7. CROWD-OUT closed: the permissionless RevenueDistributor.notifyRevenue path can NO LONGER
    //    register reward tokens, so a griefer cannot fill the capped set with junk and strand a
    //    legitimate token's staker revenue (the HIGH the convergence audit found in register-at-notify).
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_HIGH_crowdOut_viaNotifyRevenue_isImpossible() public {
        MintableERC20 junk = new MintableERC20("J", "J");
        junk.mint(address(rev), 2);
        rev.notifyRevenue(address(junk), 2); // credits pending but must NOT register the token
        assertFalse(staking.isRewardToken(address(junk)), "junk registered via notifyRevenue (crowd-out)");
        assertEq(staking.rewardTokenCount(), 1, "only the admin-added USD is registered");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 8. POISON closed: even if a transfer-reverting token is (mistakenly) allowlisted, or a curated
    //    stable later blacklists this contract, stake/unstake are ISOLATED per-token and NEVER brick —
    //    staked principal always exits. FAILS without the try/catch isolation (unstake reverts,
    //    locking all principal); PASSES with it.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_HIGH_poisonToken_cannotBrickStakeUnstake() public {
        // A reward token whose transfer to this contract reverts under SafeERC20 (blacklist/pausable proxy).
        ReturnsFalseERC20 bad = new ReturnsFalseERC20();
        staking.addRewardToken(address(bad)); // admin allowlists it (or a good stable that later goes bad)

        vm.prank(alice);
        staking.stake(100e18, 0); // principal at risk

        // Create staker pending in the bad token so _harvestAll will attempt (and fail) its pull.
        bad.mint(address(rev), 4);
        rev.notifyRevenue(address(bad), 4); // pending(staking, bad) = 2
        assertEq(rev.pending(address(staking), address(bad)), 2, "bad pending not set");

        // Unstake must survive the poisoned token: the bad pull is caught and skipped, principal returns.
        uint256 balBefore = fera.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(100e18); // MUST NOT revert (pre-isolation: reverts, principal locked forever)
        assertEq(fera.balanceOf(alice) - balBefore, 100e18, "principal not returned");

        // A fresh stake also survives, and the good token (USD) still settles normally around the bad one.
        _sendStakerRevenue(30e18);
        vm.prank(bob);
        staking.stake(50e18, 0); // MUST NOT revert
        vm.prank(bob);
        staking.stake(50e18, 0);
        // USD keeps working; the poisoned token's pending simply waits (never lost, never bricking).
        assertEq(rev.pending(address(staking), address(bad)), 2, "bad pending should still be waiting");
    }
}
