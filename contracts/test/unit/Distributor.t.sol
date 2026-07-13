// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "../../src/Distributor.sol";
import {IDistributor} from "../../src/interfaces/IDistributor.sol";
import {IEsFera} from "../../src/interfaces/IEsFera.sol";
import {IEmissionsController} from "../../src/interfaces/IEmissionsController.sol";
import {MockEsFera, MockEmissionsController} from "../utils/Mocks.sol";

/// @notice INV-8 — a Merkle claim for a given (epochId, account, kind) can be claimed AT MOST once.
/// @dev    Leaf is FROZEN (MASTER_SPEC §9): keccak256(abi.encode(epochId, account, kind, amount)),
///         with OpenZeppelin sorted-pair proof verification. Tree here = two leaves for the SAME
///         account, different kinds, so the per-(epoch,account,kind) bitmap is exercised precisely.
contract DistributorTest is Test {
    Distributor internal dist;
    MockEsFera internal es;
    MockEmissionsController internal controller;

    address internal poster = makeAddr("rootPoster");
    address internal alice = makeAddr("alice");

    uint256 internal constant EPOCH = 1;
    uint256 internal constant AMOUNT0 = 100 ether; // trader rebate (kind 0)
    uint256 internal constant AMOUNT1 = 50 ether; // lp reward (kind 1)

    bytes32 internal leaf0;
    bytes32 internal leaf1;
    bytes32 internal root;

    function setUp() public {
        es = new MockEsFera();
        controller = new MockEmissionsController();
        dist = new Distributor(IEsFera(address(es)), poster, IEmissionsController(address(controller)));

        // R-19: the controller must have finalized/funded EXACTLY the total the root distributes.
        controller.setEmitted(EPOCH, AMOUNT0 + AMOUNT1);

        // FROZEN leaf encoding (kind is uint8 to match Distributor.claim's abi.encode).
        leaf0 = keccak256(abi.encode(EPOCH, alice, uint8(0), AMOUNT0));
        leaf1 = keccak256(abi.encode(EPOCH, alice, uint8(1), AMOUNT1));
        root = _commutative(leaf0, leaf1);

        vm.prank(poster);
        dist.postRoot(EPOCH, root, AMOUNT0 + AMOUNT1);
    }

    function _commutative(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function test_postRoot_onlyPoster() public {
        vm.expectRevert(IDistributor.OnlyRootPoster.selector);
        dist.postRoot(2, root, 0);
    }

    function test_postRoot_oncePerEpoch() public {
        vm.prank(poster);
        vm.expectRevert(IDistributor.RootAlreadyPosted.selector);
        dist.postRoot(EPOCH, root, 0);
    }

    /// Happy path: alice claims kind 0 then kind 1 (independent bits), both mint esFERA.
    function test_claim_bothKinds() public {
        bytes32[] memory proof0 = new bytes32[](1);
        proof0[0] = leaf1;
        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf0;

        vm.prank(alice);
        dist.claim(EPOCH, 0, AMOUNT0, proof0);
        assertTrue(dist.isClaimed(EPOCH, alice, 0));

        vm.prank(alice);
        dist.claim(EPOCH, 1, AMOUNT1, proof1);
        assertTrue(dist.isClaimed(EPOCH, alice, 1));

        assertEq(es.totalMinted(), AMOUNT0 + AMOUNT1, "esFERA not minted for both claims");
    }

    /// INV-8: the SAME (epoch, account, kind) cannot be claimed twice.
    function test_claim_doubleClaimReverts() public {
        bytes32[] memory proof0 = new bytes32[](1);
        proof0[0] = leaf1;

        vm.prank(alice);
        dist.claim(EPOCH, 0, AMOUNT0, proof0);

        vm.prank(alice);
        vm.expectRevert(IDistributor.AlreadyClaimed.selector);
        dist.claim(EPOCH, 0, AMOUNT0, proof0);
    }

    /// A wrong amount (or account/kind) fails proof verification.
    function test_claim_wrongAmountReverts() public {
        bytes32[] memory proof0 = new bytes32[](1);
        proof0[0] = leaf1;

        vm.prank(alice);
        vm.expectRevert(IDistributor.InvalidProof.selector);
        dist.claim(EPOCH, 0, AMOUNT0 + 1, proof0);
    }

    /// A non-included account cannot claim.
    function test_claim_wrongAccountReverts() public {
        bytes32[] memory proof0 = new bytes32[](1);
        proof0[0] = leaf1;

        vm.prank(makeAddr("mallory"));
        vm.expectRevert(IDistributor.InvalidProof.selector);
        dist.claim(EPOCH, 0, AMOUNT0, proof0);
    }

    /// Claiming against an unposted epoch reverts.
    function test_claim_noRootReverts() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1;

        vm.prank(alice);
        vm.expectRevert(IDistributor.RootNotPosted.selector);
        dist.claim(999, 0, AMOUNT0, proof);
    }

    // ── R-19 / D-M9 C2 — Σleaves == emitted (funded envelope binding) ────────────────────────

    /// postRoot for an epoch the controller has not finalized/funded reverts.
    function test_R19_postRoot_unfinalizedEpochReverts() public {
        vm.prank(poster);
        vm.expectRevert(IDistributor.EpochNotFinalized.selector);
        dist.postRoot(7, root, AMOUNT0 + AMOUNT1); // epoch 7 never funded
    }

    /// postRoot whose total != the funded amount reverts (a compromised poster cannot over-post).
    function test_R19_postRoot_totalMustEqualEmitted() public {
        controller.setEmitted(2, AMOUNT0 + AMOUNT1);
        vm.prank(poster);
        vm.expectRevert(IDistributor.EmittedMismatch.selector);
        dist.postRoot(2, root, AMOUNT0 + AMOUNT1 + 1); // one wei over the funded envelope
    }

    /// Even with a validly-posted root, cumulative claims can never exceed the funded total: a root
    /// whose leaves over-sum the envelope has its final claim capped (hard on-chain bound).
    function test_R19_claimsCappedAtEmitted() public {
        // Epoch 2 funded with ONLY AMOUNT0, but the posted root embeds two leaves summing to more.
        controller.setEmitted(2, AMOUNT0);
        bytes32 l0 = keccak256(abi.encode(uint256(2), alice, uint8(0), AMOUNT0));
        bytes32 l1 = keccak256(abi.encode(uint256(2), alice, uint8(1), AMOUNT1));
        bytes32 r = _commutative(l0, l1);

        vm.prank(poster);
        dist.postRoot(2, r, AMOUNT0); // legal: totalEsFera == emitted == AMOUNT0

        bytes32[] memory p0 = new bytes32[](1);
        p0[0] = l1;
        bytes32[] memory p1 = new bytes32[](1);
        p1[0] = l0;

        // First claim (AMOUNT0) fills the envelope exactly.
        vm.prank(alice);
        dist.claim(2, 0, AMOUNT0, p0);
        assertEq(dist.claimedOf(2), AMOUNT0);

        // The second leaf is a valid proof but would push cumulative claims past the funded total.
        vm.prank(alice);
        vm.expectRevert(IDistributor.ExceedsEmitted.selector);
        dist.claim(2, 1, AMOUNT1, p1);
    }

    function test_constructor_zeroRootPosterRejected() public {
        vm.expectRevert(Distributor.ZeroAddress.selector);
        new Distributor(IEsFera(address(es)), address(0), IEmissionsController(address(controller)));
    }
}
