// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeraShare} from "../../src/shares/FeraShare.sol";
import {IFeraShare} from "../../src/interfaces/IFeraShare.sol";

/// @notice COV-1 — FeraShare ERC-20 + V2-2 transfer-lock branch coverage. The per-pool vault share
///         is Vault-only mint/burn, blocks OUTGOING transfers while a depositor's cooldown is active
///         (SEC-3 #4 — can't shuttle fresh shares to a second wallet to dodge the withdraw cooldown),
///         but NEVER blocks burn/redemption (INV-11). This test drives it directly with the test
///         contract standing in for the Vault (the impl instance is inert until initialized).
contract FeraShareTest is Test {
    FeraShare internal share;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        share = new FeraShare();
        // This test contract is the "vault" — it may mint/burn/setTransferLock.
        share.initialize(address(this), bytes32("pool"), 0, "Fera Share", "fSHARE");
    }

    function test_metadata_afterInitialize() public view {
        assertEq(share.name(), "Fera Share");
        assertEq(share.symbol(), "fSHARE");
        assertEq(share.decimals(), 18);
        assertEq(share.vault(), address(this));
        assertEq(share.poolId(), bytes32("pool"));
    }

    function test_initialize_alreadyInitialized_reverts() public {
        vm.expectRevert(IFeraShare.AlreadyInitialized.selector);
        share.initialize(address(this), bytes32("x"), 0, "n", "s");
    }

    // ── onlyVault gating ────────────────────────────────────────────────────────────────────

    function test_mint_onlyVault() public {
        vm.prank(alice);
        vm.expectRevert(IFeraShare.OnlyVault.selector);
        share.mint(alice, 1e18);
    }

    function test_burn_onlyVault() public {
        share.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(IFeraShare.OnlyVault.selector);
        share.burn(alice, 1e18);
    }

    function test_setTransferLock_onlyVault() public {
        vm.prank(alice);
        vm.expectRevert(IFeraShare.OnlyVault.selector);
        share.setTransferLock(alice, uint64(block.timestamp + 1));
    }

    // ── mint / burn accounting ──────────────────────────────────────────────────────────────

    function test_mint_burn_totalSupply() public {
        share.mint(alice, 5e18);
        assertEq(share.totalSupply(), 5e18);
        assertEq(share.balanceOf(alice), 5e18);
        share.burn(alice, 2e18);
        assertEq(share.totalSupply(), 3e18);
        assertEq(share.balanceOf(alice), 3e18);
    }

    // ── V2-2 transfer-lock paths ────────────────────────────────────────────────────────────

    /// An outgoing transfer while the sender's cooldown lock is active MUST revert (SEC-3 #4).
    function test_transfer_lockedReverts_thenAllowedAfterExpiry() public {
        share.mint(alice, 10e18);
        uint64 until_ = uint64(block.timestamp + 3_600);
        share.setTransferLock(alice, until_);

        vm.prank(alice);
        vm.expectRevert(IFeraShare.TransferLocked.selector);
        share.transfer(bob, 1e18);

        // At/after the lock expiry the transfer succeeds.
        vm.warp(until_);
        vm.prank(alice);
        assertTrue(share.transfer(bob, 1e18));
        assertEq(share.balanceOf(bob), 1e18);
    }

    /// INV-11: redemption (burn) is NEVER blocked by an active transfer lock — the Vault can always
    /// process a withdraw even mid-cooldown (the cooldown gates the withdraw call itself, not burn).
    function test_burn_notBlockedByActiveLock() public {
        share.mint(alice, 10e18);
        share.setTransferLock(alice, uint64(block.timestamp + 10_000));
        share.burn(alice, 4e18); // must NOT revert
        assertEq(share.balanceOf(alice), 6e18);
    }

    /// Mint is exempt from the lock (from == address(0) path never checks the sender lock).
    function test_mint_exemptFromLock() public {
        share.setTransferLock(alice, uint64(block.timestamp + 10_000));
        share.mint(alice, 1e18); // must NOT revert
        assertEq(share.balanceOf(alice), 1e18);
    }

    /// setTransferLock is extend-only: a shorter `until` can never shrink an active lock.
    function test_setTransferLock_extendOnly() public {
        uint64 far = uint64(block.timestamp + 10_000);
        share.setTransferLock(alice, far);
        share.setTransferLock(alice, uint64(block.timestamp + 1)); // shorter — ignored
        assertEq(share.transferLockUntil(alice), far, "lock was shortened");
    }

    // ── ERC-20 approve / transferFrom (finite + infinite allowance) ──────────────────────────

    function test_approve_and_transferFrom_finiteAllowance() public {
        share.mint(alice, 10e18);
        vm.prank(alice);
        assertTrue(share.approve(bob, 4e18));
        assertEq(share.allowance(alice, bob), 4e18);

        vm.prank(bob);
        assertTrue(share.transferFrom(alice, carol, 3e18));
        assertEq(share.balanceOf(carol), 3e18);
        assertEq(share.allowance(alice, bob), 1e18, "finite allowance not decremented");
    }

    /// Infinite allowance (type(uint256).max) is NOT decremented on transferFrom.
    function test_transferFrom_infiniteAllowance_notDecremented() public {
        share.mint(alice, 10e18);
        vm.prank(alice);
        share.approve(bob, type(uint256).max);
        vm.prank(bob);
        share.transferFrom(alice, carol, 3e18);
        assertEq(share.allowance(alice, bob), type(uint256).max, "infinite allowance was decremented");
    }

    /// transferFrom is also gated by the sender's transfer lock (routes through _transfer).
    function test_transferFrom_respectsTransferLock() public {
        share.mint(alice, 10e18);
        vm.prank(alice);
        share.approve(bob, type(uint256).max);
        share.setTransferLock(alice, uint64(block.timestamp + 3_600));
        vm.prank(bob);
        vm.expectRevert(IFeraShare.TransferLocked.selector);
        share.transferFrom(alice, carol, 1e18);
    }

    function test_initialize_zeroVaultRejected() public {
        FeraShare fresh = new FeraShare();
        vm.expectRevert(FeraShare.ZeroAddress.selector);
        fresh.initialize(address(0), bytes32("p"), 0, "n", "s");
    }
}
