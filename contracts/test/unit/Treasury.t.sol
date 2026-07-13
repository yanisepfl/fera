// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../../src/Treasury.sol";
import {ITreasury} from "../../src/interfaces/ITreasury.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

/// @notice INV-12 — mutable/spend paths are timelocked 48h. The Treasury queues → waits DELAY →
///         executes; no hot key can move protocol funds without the delay.
contract TreasuryTarget {
    uint256 public poked;

    function poke(uint256 v) external payable {
        poked = v;
    }

    function boom() external pure {
        revert("target reverted");
    }
}

contract TreasuryTest is Test {
    Treasury internal treasury;
    TreasuryTarget internal target;

    function setUp() public {
        treasury = new Treasury(address(this)); // this is the governor
        target = new TreasuryTarget();
    }

    function test_delay_is48h() public view {
        assertEq(treasury.DELAY(), FeraConstants.TIMELOCK_DELAY);
        assertEq(treasury.DELAY(), 48 hours);
    }

    function test_execute_beforeEtaReverts() public {
        bytes memory data = abi.encodeCall(TreasuryTarget.poke, (42));
        uint256 eta = block.timestamp + treasury.DELAY();
        treasury.queue(address(target), 0, data);

        vm.expectRevert(ITreasury.NotReady.selector);
        treasury.execute(address(target), 0, data, eta);
    }

    function test_execute_afterDelaySucceeds() public {
        bytes memory data = abi.encodeCall(TreasuryTarget.poke, (42));
        uint256 eta = block.timestamp + treasury.DELAY();
        treasury.queue(address(target), 0, data);

        vm.warp(eta);
        treasury.execute(address(target), 0, data, eta);
        assertEq(target.poked(), 42, "execute did not run after delay");
    }

    function test_queue_onlyOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // Ownable: unauthorized
        treasury.queue(address(target), 0, "");
    }

    function test_cancel_preventsExecute() public {
        bytes memory data = abi.encodeCall(TreasuryTarget.poke, (7));
        uint256 eta = block.timestamp + treasury.DELAY();
        bytes32 id = treasury.queue(address(target), 0, data);

        treasury.cancel(id);
        vm.warp(eta);
        vm.expectRevert(ITreasury.NotReady.selector);
        treasury.execute(address(target), 0, data, eta);
    }

    // ── COV-1: timelock queue/execute/cancel error branches ─────────────────────────────────

    /// Queuing the exact same (target,value,data) twice in the SAME block ⇒ identical eta ⇒ identical
    /// id ⇒ AlreadyQueued (the dedupe guard that stops a double-queue from splitting the timelock).
    function test_queue_alreadyQueued_reverts() public {
        bytes memory data = abi.encodeCall(TreasuryTarget.poke, (1));
        treasury.queue(address(target), 0, data);
        vm.expectRevert(ITreasury.AlreadyQueued.selector);
        treasury.queue(address(target), 0, data); // same block ⇒ same eta ⇒ same id
    }

    /// A queued, matured call whose target reverts ⇒ CallReverted, and the id is left consumed
    /// (effects-before-interaction: `queued[id]` was cleared before the failing call).
    function test_execute_callReverts() public {
        bytes memory data = abi.encodeCall(TreasuryTarget.boom, ());
        uint256 eta = block.timestamp + treasury.DELAY();
        treasury.queue(address(target), 0, data);
        vm.warp(eta);
        vm.expectRevert(ITreasury.CallReverted.selector);
        treasury.execute(address(target), 0, data, eta);
    }

    /// Executing a call that was never queued (here: a wrong eta) ⇒ NotReady on the `!queued[id]` leg.
    function test_execute_neverQueued_reverts() public {
        bytes memory data = abi.encodeCall(TreasuryTarget.poke, (5));
        uint256 eta = block.timestamp + treasury.DELAY();
        treasury.queue(address(target), 0, data);
        vm.warp(eta);
        // Same call, WRONG eta ⇒ different id ⇒ not queued.
        vm.expectRevert(ITreasury.NotReady.selector);
        treasury.execute(address(target), 0, data, eta + 1);
    }

    /// Cancelling an id that was never queued ⇒ NotReady.
    function test_cancel_notQueued_reverts() public {
        vm.expectRevert(ITreasury.NotReady.selector);
        treasury.cancel(keccak256("never-queued"));
    }

    /// cancel + execute are owner-gated (Ownable).
    function test_cancel_and_execute_onlyOwner() public {
        bytes memory data = abi.encodeCall(TreasuryTarget.poke, (9));
        uint256 eta = block.timestamp + treasury.DELAY();
        bytes32 id = treasury.queue(address(target), 0, data);
        vm.warp(eta);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        treasury.cancel(id);
        vm.prank(stranger);
        vm.expectRevert();
        treasury.execute(address(target), 0, data, eta);
    }

    /// A matured queued call with ETH `value` forwards the funds to the target (execute value leg).
    function test_execute_forwardsValue() public {
        vm.deal(address(treasury), 1 ether);
        bytes memory data = abi.encodeCall(TreasuryTarget.poke, (77));
        uint256 eta = block.timestamp + treasury.DELAY();
        treasury.queue(address(target), 1 ether, data);
        vm.warp(eta);
        treasury.execute(address(target), 1 ether, data, eta);
        assertEq(address(target).balance, 1 ether, "value not forwarded");
        assertEq(target.poked(), 77, "call did not run");
    }
}
