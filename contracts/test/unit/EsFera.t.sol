// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EsFera} from "../../src/EsFera.sol";
import {FeraToken} from "../../src/FeraToken.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {AnchorStaking} from "../../src/AnchorStaking.sol";
import {IFeraToken} from "../../src/interfaces/IFeraToken.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IEsFera} from "../../src/interfaces/IEsFera.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice INV-9 — esFERA forfeiture conserves value: burned + toStakers + toRevenue == haircut,
///         split ~1/3 each. The instant-exit haircut is 50% (PARAMS.md#ES_HAIRCUT_BPS).
/// @dev    F-4 (v2 batch): PARAMS.md#FORFEIT_BURN_FRAC — the BURN third takes the ≤2-wei rounding
///         remainder (spec-aligned 2026-07-11; the earlier remainder-to-revenue drift is resolved).
contract EsFeraTest is Test {
    FeraToken internal fera;
    EsFera internal es;
    RevenueDistributor internal rev;
    AnchorStaking internal staking;

    // REC-8: staking is now the REAL AnchorStaking (the forfeit stakers-third is BOOKED into it, not
    // sent to an EOA). `stakingAddr` aliases it so the existing conservation asserts are unchanged.
    address internal stakingAddr;
    address internal treasury = makeAddr("treasury");
    address internal ops = makeAddr("ops");

    function setUp() public {
        // Genesis 10% FERA mints to this test contract (acting as the genesis treasury).
        fera = new FeraToken(address(this));

        // Break the AnchorStaking↔RevenueDistributor ctor cycle by predicting staking's address.
        address predictedStaking = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rev = new RevenueDistributor(predictedStaking, treasury, ops);
        // rewardTokenAdmin = this test contract (governance) so we can curate the allowlist + notifier.
        staking = new AnchorStaking(IERC20(address(fera)), IRevenueDistributor(address(rev)), address(this));
        require(address(staking) == predictedStaking, "staking addr mismatch");
        stakingAddr = address(staking);

        // minter = this test, so we can mintAndVest directly.
        es = new EsFera(IFeraToken(address(fera)), IAnchorStaking(address(staking)), IRevenueDistributor(address(rev)), address(this));

        // REC-8 deploy dependency: FERA must be an allowlisted reward token and EsFera must be the
        // forfeit notifier for the stakers-third to be booked into the reward accumulator.
        staking.addRewardToken(address(fera));
        staking.setForfeitNotifier(address(es));

        // Fund the escrow with FERA backing (EmissionsController does this 1:1 in production). Keep some
        // FERA in the test contract for staking scenarios (genesis 1e26; escrow gets 9e25).
        IERC20(address(fera)).transfer(address(es), 9e25);
    }

    function test_mintAndVest_onlyMinter() public {
        vm.prank(makeAddr("notMinter"));
        vm.expectRevert(IEsFera.OnlyMinter.selector);
        es.mintAndVest(address(this), 1e18);
    }

    /// Core INV-9: instant-exit forfeit routing conserves value exactly and splits into thirds.
    function testFuzz_instantExit_conservesForfeit(uint256 amount) public {
        amount = bound(amount, 3, 1e25);
        es.mintAndVest(address(this), amount);

        uint256 esBalBefore = fera.balanceOf(address(es));
        uint256 supplyBefore = fera.totalSupply();
        uint256 stakerBefore = fera.balanceOf(stakingAddr);
        uint256 revBefore = fera.balanceOf(address(rev));
        uint256 userBefore = fera.balanceOf(address(this));

        uint256 feraOut = es.instantExit(amount);

        uint256 haircut = (amount * FeraConstants.INSTANT_EXIT_HAIRCUT_BPS) / FeraConstants.BPS;
        assertEq(feraOut, amount - haircut, "feraOut != amount - 50%");

        uint256 burned = supplyBefore - fera.totalSupply();
        uint256 toStakers = fera.balanceOf(stakingAddr) - stakerBefore;
        uint256 toRevenue = fera.balanceOf(address(rev)) - revBefore;

        // INV-9: value conservation of the forfeited half.
        assertEq(burned + toStakers + toRevenue, haircut, "forfeit not conserved");

        // Thirds (F-4): stakers/revenue are floor(h/3); the BURN carries the ≤2-wei remainder
        // (PARAMS.md#FORFEIT_BURN_FRAC — dust is destroyed, never paid out).
        assertEq(toStakers, haircut / FeraConstants.FORFEIT_PARTS, "stakers != 1/3");
        assertEq(toRevenue, haircut / FeraConstants.FORFEIT_PARTS, "revenue != 1/3");
        assertLe(burned - (haircut / FeraConstants.FORFEIT_PARTS), 2, "burn remainder > 2 wei");
        assertGe(burned, haircut / FeraConstants.FORFEIT_PARTS, "burn below 1/3");

        // User received exactly feraOut; escrow drained exactly `amount` (feraOut + haircut).
        assertEq(fera.balanceOf(address(this)) - userBefore, feraOut, "user payout mismatch");
        assertEq(esBalBefore - fera.balanceOf(address(es)), amount, "escrow drain != amount");

        // Revenue third was booked into the RevenueDistributor accounting.
        assertEq(rev.pending(stakingAddr, address(fera)) + rev.pending(treasury, address(fera))
            + rev.pending(ops, address(fera)), toRevenue, "revenue not accounted");
    }

    /// Linear vest: nothing claimable at t0, half at midpoint, all after end.
    function test_vest_linearSchedule() public {
        uint256 amount = 1e21;
        es.mintAndVest(makeAddr("alice"), amount);
        address alice = makeAddr("alice");

        assertEq(es.claimable(alice), 0, "claimable at t0");

        vm.warp(block.timestamp + FeraConstants.ES_VEST_DURATION / 2);
        assertApproxEqAbs(es.claimable(alice), amount / 2, 1e6, "half not vested at midpoint");

        vm.warp(block.timestamp + FeraConstants.ES_VEST_DURATION);
        assertEq(es.claimable(alice), amount, "not fully vested after end");
    }

    function test_instantExit_zeroReverts() public {
        vm.expectRevert(IEsFera.ZeroAmount.selector);
        es.instantExit(0);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // REC-8 — the forfeit stakers-third is actually BOOKED to stakers (was a stranded TODO).
    // With a staker present, instantExit's stakers-third folds into accPerShare[FERA] and the
    // staker can claim it; conservation burned + stakers + revenue == haircut still holds.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_REC8_forfeitStakersThird_reachesStakers() public {
        address staker = makeAddr("staker");
        uint256 stakeAmt = 1_000e18;
        IERC20(address(fera)).transfer(staker, stakeAmt);
        vm.startPrank(staker);
        IERC20(address(fera)).approve(address(staking), type(uint256).max);
        staking.stake(stakeAmt);
        vm.stopPrank();

        uint256 amount = 300e18;
        es.mintAndVest(address(this), amount);
        uint256 supplyBefore = fera.totalSupply();

        es.instantExit(amount);

        uint256 haircut = (amount * FeraConstants.INSTANT_EXIT_HAIRCUT_BPS) / FeraConstants.BPS;
        uint256 toStakers = haircut / FeraConstants.FORFEIT_PARTS;
        uint256 toRevenue = haircut / FeraConstants.FORFEIT_PARTS;
        uint256 burned = supplyBefore - fera.totalSupply();

        // INV-9 conservation unchanged by the wiring.
        assertEq(burned + toStakers + toRevenue, haircut, "forfeit not conserved");

        // REC-8 CORE: the stakers-third is booked into the FERA accumulator (was stranded pre-fix).
        // The view reflects ONLY the booked forfeit third (the revenue third sits unharvested in the
        // distributor until a harvest), so it equals toStakers exactly for the sole staker.
        assertEq(staking.claimableRevenue(staker, address(fera)), toStakers, "REC-8: forfeit third not booked");

        // Claiming ALSO harvests the staker's 50% of the revenue third from the distributor.
        uint256 revThirdStaker = rev.pending(address(staking), address(fera));
        vm.prank(staker);
        uint256 claimed = staking.claimRevenueShare(address(fera));
        assertEq(claimed, toStakers + revThirdStaker, "staker claim != forfeit third + revenue third");

        // Only the staked principal remains in the contract; the staker can unstake it cleanly
        // (warp past the v3.4 7-day unstake cooldown re-armed by their stake).
        vm.warp(block.timestamp + FeraConstants.UNSTAKE_COOLDOWN_SEC + 1);
        assertEq(fera.balanceOf(address(staking)), stakeAmt, "staking should hold exactly staked principal");
        vm.prank(staker);
        staking.unstake(stakeAmt);
        assertEq(fera.balanceOf(staker), stakeAmt + toStakers + revThirdStaker, "staker final balance wrong");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // REC-8 liveness — instant-exit is NEVER bricked by staking having no stakers yet: the
    // stakers-third is HELD as pendingForfeitFera (still physically at staking) and folds in later.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_REC8_forfeitBeforeAnyStaker_heldThenBookedOnFirstStake() public {
        uint256 amount = 300e18;
        es.mintAndVest(address(this), amount);
        es.instantExit(amount); // totalStaked == 0 ⇒ notifyForfeitShare holds, does NOT revert

        uint256 toStakers = ((amount * FeraConstants.INSTANT_EXIT_HAIRCUT_BPS) / FeraConstants.BPS) / FeraConstants.FORFEIT_PARTS;
        assertEq(staking.pendingForfeitFera(), toStakers, "held forfeit not recorded");
        assertEq(fera.balanceOf(address(staking)), toStakers, "held forfeit not physically present");
        // The revenue third (50% of it) is also owed to stakers, waiting unharvested in the distributor.
        uint256 revThirdStaker = rev.pending(address(staking), address(fera));

        // First staker joins; then a claim harvests FERA, folding BOTH the held forfeit third and the
        // revenue-third staker portion into the accumulator (the staker present at the fold gets it all).
        address staker = makeAddr("staker");
        uint256 stakeAmt = 1_000e18;
        IERC20(address(fera)).transfer(staker, stakeAmt);
        vm.startPrank(staker);
        IERC20(address(fera)).approve(address(staking), type(uint256).max);
        staking.stake(stakeAmt);
        uint256 claimed = staking.claimRevenueShare(address(fera));
        vm.stopPrank();
        assertEq(staking.pendingForfeitFera(), 0, "held forfeit not folded after first stake+claim");
        assertEq(claimed, toStakers + revThirdStaker, "first staker did not receive held forfeit + revenue third");
    }

    function test_constructor_zeroMinterRejected() public {
        vm.expectRevert(EsFera.ZeroAddress.selector);
        new EsFera(IFeraToken(address(fera)), IAnchorStaking(address(staking)), IRevenueDistributor(address(rev)), address(0));
    }
}
