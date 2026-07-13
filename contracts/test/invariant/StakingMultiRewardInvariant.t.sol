// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {AnchorStaking} from "../../src/AnchorStaking.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {FeraToken} from "../../src/FeraToken.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MintableERC20} from "../utils/Mocks.sol";

/// @dev Interleaves stake / unstake / multi-token revenue-notify / per-token claim across 3 actors and
///      2 distinct reward tokens (R-21 MasterChef multi-reward path). The invariant contract then
///      checks, at every step, that the accounting is conservative (no reward invented, principal always
///      withdrawable, reward-token payouts always backed by real balance).
contract StakingMultiRewardHandler is Test {
    AnchorStaking internal staking;
    RevenueDistributor internal rev;
    FeraToken internal fera;
    MintableERC20 internal usd;
    MintableERC20 internal weth;

    address[3] internal actors;
    address[2] internal rewardTokens;

    // ghosts, keyed by reward token
    mapping(address => uint256) public ghostStakerRevenue; // Σ of the 50% staker slice routed in
    mapping(address => uint256) public ghostClaimed; // Σ pulled out by actors via claimRevenueShare

    constructor(
        AnchorStaking staking_,
        RevenueDistributor rev_,
        FeraToken fera_,
        MintableERC20 usd_,
        MintableERC20 weth_,
        address[3] memory actors_
    ) {
        staking = staking_;
        rev = rev_;
        fera = fera_;
        usd = usd_;
        weth = weth_;
        actors = actors_;
        rewardTokens = [address(usd_), address(weth_)];
    }

    function rewardTokenAt(uint256 i) external view returns (address) {
        return rewardTokens[i];
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    // ── Actions ─────────────────────────────────────────────────────────────────────────────

    function stakeFor(uint256 actorSeed, uint256 amtSeed, uint256 lockSeed) external {
        address a = actors[actorSeed % 3];
        uint256 bal = fera.balanceOf(a);
        if (bal == 0) return;
        uint256 amt = bound(amtSeed, 1, bal);
        vm.prank(a);
        staking.stake(amt, bound(lockSeed, 0, 2));
    }

    function unstakeFor(uint256 actorSeed, uint256 amtSeed) external {
        address a = actors[actorSeed % 3];
        uint256 st = staking.stakedOf(a);
        if (st == 0) return;
        uint256 amt = bound(amtSeed, 1, st);
        vm.prank(a);
        staking.unstake(amt); // reverts (skipped) if still locked — fail_on_revert = false
    }

    function notify(uint256 tokenSeed, uint256 amtSeed) external {
        address t = rewardTokens[tokenSeed % 2];
        uint256 amt = bound(amtSeed, 2, 1e24);
        MintableERC20(t).mint(address(rev), amt);
        rev.notifyRevenue(t, amt);
        ghostStakerRevenue[t] += (amt * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS;
    }

    function claimFor(uint256 actorSeed, uint256 tokenSeed) external {
        address a = actors[actorSeed % 3];
        address t = rewardTokens[tokenSeed % 2];
        vm.prank(a);
        uint256 got = staking.claimRevenueShare(t);
        ghostClaimed[t] += got;
    }

    function warp(uint256 dtSeed) external {
        vm.warp(block.timestamp + bound(dtSeed, 1 hours, 21 days));
    }
}

/// @notice AnchorStaking multi-reward accounting invariants (R-21 / REC-6/7) under interleaved
///         stake/notify/claim. Conservation, principal solvency, and reward-token solvency.
contract StakingMultiRewardInvariant is StdInvariant, Test {
    AnchorStaking internal staking;
    RevenueDistributor internal rev;
    FeraToken internal fera;
    MintableERC20 internal usd;
    MintableERC20 internal weth;
    StakingMultiRewardHandler internal handler;

    address internal treasury = makeAddr("treasury");
    address internal ops = makeAddr("ops");
    address[3] internal actors;

    function setUp() public {
        fera = new FeraToken(address(this)); // genesis 10% (1e26) here
        usd = new MintableERC20("USD", "USD");
        weth = new MintableERC20("WETH", "WETH");

        address predictedStaking = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rev = new RevenueDistributor(predictedStaking, treasury, ops);
        staking = new AnchorStaking(IERC20(address(fera)), IRevenueDistributor(address(rev)), address(this));
        require(address(staking) == predictedStaking, "staking addr");

        // Allowlist the two NON-principal reward tokens (FERA stays pure principal ⇒ crisp solvency).
        staking.addRewardToken(address(usd));
        staking.addRewardToken(address(weth));

        actors = [makeAddr("stkA"), makeAddr("stkB"), makeAddr("stkC")];
        for (uint256 i; i < 3; ++i) {
            fera.transfer(actors[i], 1e24);
            vm.prank(actors[i]);
            fera.approve(address(staking), type(uint256).max);
        }

        handler = new StakingMultiRewardHandler(staking, rev, fera, usd, weth, actors);

        bytes4[] memory sel = new bytes4[](5);
        sel[0] = handler.stakeFor.selector;
        sel[1] = handler.unstakeFor.selector;
        sel[2] = handler.notify.selector;
        sel[3] = handler.claimFor.selector;
        sel[4] = handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// totalStaked is always exactly the sum of individual stakes (no accounting drift).
    function invariant_totalStakedEqualsSum() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += staking.stakedOf(actors[i]);
        }
        assertEq(staking.totalStaked(), sum, "totalStaked != sum stakedOf");
    }

    /// Staked FERA principal is ALWAYS fully withdrawable — the contract holds ≥ totalStaked FERA
    /// (FERA is not a reward token here, so its balance is exactly the staked principal).
    function invariant_principalSolvent() public view {
        assertGe(fera.balanceOf(address(staking)), staking.totalStaked(), "principal underfunded");
    }

    /// Per reward token: nothing is invented. Claimed-out + still-claimable never exceeds the revenue
    /// actually routed to stakers (floor-division dust only makes the LHS strictly smaller).
    function invariant_rewardConservation() public view {
        for (uint256 j; j < 2; ++j) {
            address t = handler.rewardTokenAt(j);
            uint256 claimable;
            for (uint256 i; i < 3; ++i) {
                claimable += staking.claimableRevenue(actors[i], t);
            }
            assertLe(
                handler.ghostClaimed(t) + claimable, handler.ghostStakerRevenue(t), "reward over-distributed"
            );
        }
    }

    /// Per reward token: every unit still owed to stakers (settled + harvested-unclaimed) is physically
    /// held by the contract — a claim can never revert for insufficient balance.
    function invariant_rewardSolvent() public view {
        for (uint256 j; j < 2; ++j) {
            address t = handler.rewardTokenAt(j);
            uint256 owed;
            for (uint256 i; i < 3; ++i) {
                owed += staking.claimableRevenue(actors[i], t);
            }
            assertGe(MintableERC20(t).balanceOf(address(staking)), owed, "reward payouts not backed by balance");
        }
    }
}
