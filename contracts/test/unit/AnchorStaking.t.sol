// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AnchorStaking} from "../../src/AnchorStaking.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {FeraToken} from "../../src/FeraToken.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deterministic unit coverage for AnchorStaking (sFERA, v3.4 SIMPLE model): stake/unstake
///         accounting (R-21), zero-amount + 7-day unstake-cooldown guards (the single anti reward-JIT
///         time element — power is flat, no boost/locks), the pull→accumulator→pro-rata revenue path,
///         the reward-token allowlist (REC-6/REC-7), and the forfeit-notifier wiring (REC-8).
///         Complements the multi-reward stateful invariant.
contract AnchorStakingTest is Test {
    FeraToken internal fera;
    RevenueDistributor internal rev;
    AnchorStaking internal staking;

    address internal treasury = makeAddr("treasury");
    address internal ops = makeAddr("ops");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        fera = new FeraToken(address(this)); // genesis 10% (1e26) to this test contract

        // Break the AnchorStaking↔RevenueDistributor ctor cycle by predicting staking's address.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rev = new RevenueDistributor(predicted, treasury, ops);
        staking = new AnchorStaking(IERC20(address(fera)), IRevenueDistributor(address(rev)), address(this));
        require(address(staking) == predicted, "staking addr mismatch");

        // FERA is the canonical reward token (revenue routes FERA to stakers).
        staking.addRewardToken(address(fera));

        // Fund actors.
        IERC20(address(fera)).transfer(alice, 1_000e18);
        IERC20(address(fera)).transfer(bob, 1_000e18);
    }

    function _stake(address who, uint256 amt) internal {
        vm.startPrank(who);
        IERC20(address(fera)).approve(address(staking), amt);
        staking.stake(amt);
        vm.stopPrank();
    }

    /// Route `amount` of FERA revenue to the distributor so the stakers-arm accrues (50%).
    function _routeRevenue(uint256 amount) internal {
        IERC20(address(fera)).transfer(address(rev), amount);
        rev.notifyRevenue(address(fera), amount);
    }

    // ── stake / unstake ────────────────────────────────────────────────────────────────────
    function test_stake_updatesBalances() public {
        _stake(alice, 100e18);
        assertEq(staking.stakedOf(alice), 100e18, "staked balance");
        assertEq(staking.totalStaked(), 100e18, "total staked");
    }

    function test_stake_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(IAnchorStaking.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_unstake_zeroReverts() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(IAnchorStaking.ZeroAmount.selector);
        staking.unstake(0);
    }

    function test_unstake_returnsPrincipal() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + FeraConstants.UNSTAKE_COOLDOWN_SEC + 1); // past the 7d cooldown
        vm.prank(alice);
        staking.unstake(40e18);
        assertEq(staking.stakedOf(alice), 60e18, "remaining stake");
        assertEq(staking.totalStaked(), 60e18, "total after unstake");
        assertEq(IERC20(address(fera)).balanceOf(alice), 1_000e18 - 60e18, "principal not returned");
    }

    function test_unstakeCooldown_blocksEarlyUnstake_andTopUpsReArm() public {
        _stake(alice, 100e18);
        // Immediate unstake is blocked by the 7-day cooldown (anti reward-JIT).
        vm.prank(alice);
        vm.expectRevert(IAnchorStaking.StillLocked.selector);
        staking.unstake(10e18);
        assertEq(staking.unstakeAvailableAt(alice), block.timestamp + FeraConstants.UNSTAKE_COOLDOWN_SEC, "cooldown view off");

        // A top-up 6 days in re-arms the clock on the WHOLE balance (conservative by design)...
        vm.warp(block.timestamp + 6 days);
        _stake(alice, 1e18);
        vm.warp(block.timestamp + 2 days); // 8d past the first stake, but only 2d past the top-up
        vm.prank(alice);
        vm.expectRevert(IAnchorStaking.StillLocked.selector);
        staking.unstake(10e18);

        // ...and once 7d pass since the LAST stake, unstaking works.
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(alice);
        staking.unstake(10e18);
        assertEq(staking.stakedOf(alice), 91e18, "unstake after cooldown failed");
    }

    // ── revenue distribution (R-21 pro-rata) ─────────────────────────────────────────────────
    function test_revenueShare_proRata() public {
        _stake(alice, 100e18);
        _stake(bob, 300e18); // alice 25%, bob 75%

        _routeRevenue(400e18); // stakers arm = 50% = 200e18
        staking.harvestReward(address(fera)); // fold the pending stakers-arm into accPerShare

        uint256 aliceClaimable = staking.claimableRevenue(alice, address(fera));
        uint256 bobClaimable = staking.claimableRevenue(bob, address(fera));
        // 200e18 split 25/75 ⇒ alice ~50e18, bob ~150e18 (allow harvest-not-yet-triggered view path).
        assertApproxEqAbs(aliceClaimable, 50e18, 1e6, "alice pro-rata off");
        assertApproxEqAbs(bobClaimable, 150e18, 1e6, "bob pro-rata off");

        uint256 balBefore = IERC20(address(fera)).balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = staking.claimRevenueShare(address(fera));
        assertApproxEqAbs(claimed, 50e18, 1e6, "alice claim off");
        assertEq(IERC20(address(fera)).balanceOf(alice) - balBefore, claimed, "claim not transferred");
    }

    function test_claimRevenueShare_nonAllowlistedTokenNoOp() public {
        _stake(alice, 100e18);
        // A token that is NOT on the allowlist accrues nothing and returns 0 (no revert).
        vm.prank(alice);
        uint256 claimed = staking.claimRevenueShare(makeAddr("randomToken"));
        assertEq(claimed, 0, "non-allowlisted token should claim 0");
    }

    function test_harvestReward_permissionlessPoke() public {
        _stake(alice, 100e18);
        _routeRevenue(100e18);
        // Anyone can poke a harvest; it just folds owed revenue into the accumulator (value-neutral).
        staking.harvestReward(address(fera));
        assertGt(staking.accPerShare(address(fera)), 0, "harvest did not grow the accumulator");
    }

    // ── reward-token allowlist (REC-6/REC-7) ─────────────────────────────────────────────────
    function test_addRewardToken_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IAnchorStaking.NotRewardAdmin.selector);
        staking.addRewardToken(makeAddr("t"));
    }

    function test_addRewardToken_rejectsZeroAndDuplicate() public {
        vm.expectRevert(IAnchorStaking.InvalidRewardToken.selector);
        staking.addRewardToken(address(0));
        vm.expectRevert(IAnchorStaking.InvalidRewardToken.selector);
        staking.addRewardToken(address(fera)); // already added in setUp
    }

    function test_addRewardToken_capEnforced() public {
        // FERA already occupies 1 slot; fill to the cap then assert the next add reverts.
        uint256 remaining = staking.MAX_REWARD_TOKENS() - staking.rewardTokenCount();
        for (uint256 i; i < remaining; ++i) {
            staking.addRewardToken(makeAddr(string(abi.encode("rt", i))));
        }
        assertEq(staking.rewardTokenCount(), staking.MAX_REWARD_TOKENS(), "cap not reached");
        vm.expectRevert(IAnchorStaking.TooManyRewardTokens.selector);
        staking.addRewardToken(makeAddr("overflow"));
    }

    // ── forfeit notifier wiring (REC-8) ──────────────────────────────────────────────────────
    function test_setForfeitNotifier_onlyAdminAndWriteOnce() public {
        vm.prank(alice);
        vm.expectRevert(IAnchorStaking.NotRewardAdmin.selector);
        staking.setForfeitNotifier(makeAddr("n"));

        staking.setForfeitNotifier(makeAddr("notifier"));
        assertEq(staking.forfeitNotifier(), makeAddr("notifier"), "notifier not set");

        // Write-once.
        vm.expectRevert(IAnchorStaking.ForfeitNotifierAlreadySet.selector);
        staking.setForfeitNotifier(makeAddr("other"));
    }

    function test_notifyForfeitShare_onlyNotifier() public {
        staking.setForfeitNotifier(address(this));
        _stake(alice, 100e18);
        // Non-notifier caller reverts.
        vm.prank(alice);
        vm.expectRevert(IAnchorStaking.NotForfeitNotifier.selector);
        staking.notifyForfeitShare(1e18);

        // Notifier books it into accPerShare[FERA] (FERA is already transferred in, in production).
        IERC20(address(fera)).transfer(address(staking), 30e18);
        staking.notifyForfeitShare(30e18);
        assertGt(staking.claimableRevenue(alice, address(fera)), 0, "forfeit not booked to staker");
    }

    function test_notifyForfeitShare_heldWhenNoStakers() public {
        staking.setForfeitNotifier(address(this));
        IERC20(address(fera)).transfer(address(staking), 30e18);
        staking.notifyForfeitShare(30e18); // no stakers yet ⇒ HELD, never reverts
        assertEq(staking.pendingForfeitFera(), 30e18, "forfeit not held pending stakers");

        // First staker triggers the pending fold-in on the next harvest.
        _stake(alice, 100e18);
        staking.harvestReward(address(fera));
        assertEq(staking.pendingForfeitFera(), 0, "pending forfeit not folded in after first stake");
        assertGt(staking.claimableRevenue(alice, address(fera)), 0, "folded forfeit not claimable");
    }

    function test_constructor_zeroRewardAdminRejected() public {
        vm.expectRevert(AnchorStaking.ZeroAddress.selector);
        new AnchorStaking(IERC20(address(fera)), IRevenueDistributor(address(rev)), address(0));
    }
}
