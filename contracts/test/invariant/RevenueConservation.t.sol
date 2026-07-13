// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {MintableERC20} from "../utils/Mocks.sol";

/// @dev Handler drives random notify/pull sequences and tracks ghost totals for the conservation
///      invariant (INV-10): Σ pending + Σ pulled == Σ notified, at every step, with zero dust.
contract RevenueHandler is Test {
    RevenueDistributor internal dist;
    MintableERC20 internal token;
    address[3] internal recipients;

    uint256 public ghostNotified;
    uint256 public ghostPulled;

    constructor(RevenueDistributor dist_, MintableERC20 token_, address s, address t, address o) {
        dist = dist_;
        token = token_;
        recipients = [s, t, o];
    }

    function notify(uint256 amount) external {
        amount = bound(amount, 0, 1e24);
        token.mint(address(dist), amount);
        dist.notifyRevenue(address(token), amount);
        ghostNotified += amount;
    }

    function pull(uint256 whoSeed) external {
        address r = recipients[whoSeed % 3];
        if (dist.pending(r, address(token)) == 0) return;
        vm.prank(r);
        ghostPulled += dist.pull(address(token));
    }
}

/// @notice INV-10 (invariant form) — no inflow ever leaks: pending + pulled == notified, always.
contract RevenueConservationInvariant is StdInvariant, Test {
    RevenueDistributor internal dist;
    MintableERC20 internal token;
    RevenueHandler internal handler;

    address internal s = makeAddr("stakers");
    address internal t = makeAddr("treasury");
    address internal o = makeAddr("ops");

    function setUp() public {
        dist = new RevenueDistributor(s, t, o);
        token = new MintableERC20("USD", "USD");
        handler = new RevenueHandler(dist, token, s, t, o);
        targetContract(address(handler));
    }

    function invariant_revenueConservation() public view {
        uint256 pendingSum =
            dist.pending(s, address(token)) + dist.pending(t, address(token)) + dist.pending(o, address(token));
        assertEq(pendingSum + handler.ghostPulled(), handler.ghostNotified(), "revenue leaked (dust)");
    }

    /// The distributor never holds less than the sum of what it still owes (solvency).
    function invariant_distributorSolvent() public view {
        uint256 pendingSum =
            dist.pending(s, address(token)) + dist.pending(t, address(token)) + dist.pending(o, address(token));
        assertGe(token.balanceOf(address(dist)), pendingSum, "distributor insolvent");
    }
}
