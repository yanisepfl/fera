// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IDistributor} from "./interfaces/IDistributor.sol";
import {IEsFera} from "./interfaces/IEsFera.sol";
import {IEmissionsController} from "./interfaces/IEmissionsController.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title Distributor
/// @notice Per-epoch Merkle-root registry. One immutable root per epoch (posted by the emissions
///         keeper); users pull-claim esFERA against it. A claim for a given (epochId, account, kind)
///         can be made at most once (INV-8), enforced by a per-(epoch,account) claim bitmap.
/// @dev    Leaf is FROZEN by MASTER_SPEC §9 as:
///           leaf = keccak256(abi.encode(epochId, account, kind, amount))
///         with OpenZeppelin sorted-pair proof verification. Changing the leaf (e.g. to a
///         double-hashed leaf) is a §12 interface change — see contracts/OPEN_DECISIONS.md for the
///         standing recommendation to double-hash before mainnet.
contract Distributor is IDistributor {
    IEsFera public immutable esFera;

    /// @dev The EmissionsController that funds each epoch. postRoot binds the posted totalEsFera to
    ///      `controller.emittedOf(epochId)` and claims are capped at that total (R-19 / D-M9 C2).
    IEmissionsController public immutable controller;

    /// @dev The emissions keeper permitted to post roots (bounded: one per epoch, immutable once set).
    address public immutable rootPoster;

    mapping(uint256 => bytes32) internal _root;
    mapping(uint256 => uint256) public totalEsFeraOf;
    /// @dev Cumulative esFERA claimed per epoch — capped at totalEsFeraOf so a malicious root whose
    ///      leaves over-sum can never mint beyond the funded envelope (R-19 hard on-chain bound).
    mapping(uint256 => uint256) public claimedOf;

    /// @dev claim bitmap: _claimedBits[epochId][account] with bit `kind` set once claimed (INV-8).
    mapping(uint256 => mapping(address => uint256)) internal _claimedBits;

    /// @dev Zero-address guard on the immutable root-poster wiring (deploy sets it to the keeper).
    error ZeroAddress();

    constructor(IEsFera esFera_, address rootPoster_, IEmissionsController controller_) {
        if (rootPoster_ == address(0)) revert ZeroAddress();
        esFera = esFera_;
        rootPoster = rootPoster_;
        controller = controller_;
    }

    /// @inheritdoc IDistributor
    function postRoot(uint256 epochId, bytes32 merkleRoot, uint256 totalEsFera) external {
        if (msg.sender != rootPoster) revert OnlyRootPoster();
        if (_root[epochId] != bytes32(0)) revert RootAlreadyPosted();
        // R-19 / D-M9 C2: the posted total (== Σ leaf amounts per the §9 reproducibility bundle)
        // MUST equal the FERA the controller actually funded for this epoch. A compromised
        // root-poster therefore cannot distribute (mint esFERA) beyond the funded envelope — the
        // economic promise of INV-7 no longer rests on the poster being honest.
        if (!controller.finalized(epochId)) revert EpochNotFinalized();
        if (totalEsFera != controller.emittedOf(epochId)) revert EmittedMismatch();
        _root[epochId] = merkleRoot;
        totalEsFeraOf[epochId] = totalEsFera;
        emit RootPosted(epochId, merkleRoot, totalEsFera);
    }

    /// @inheritdoc IDistributor
    function claim(uint256 epochId, uint8 kind, uint256 amount, bytes32[] calldata proof) external {
        bytes32 root = _root[epochId];
        if (root == bytes32(0)) revert RootNotPosted();

        // FROZEN leaf encoding (MASTER_SPEC §9).
        bytes32 leaf = keccak256(abi.encode(epochId, msg.sender, kind, amount));
        if (!MerkleProof.verify(proof, root, leaf)) revert InvalidProof();

        uint256 bit = 1 << kind;
        uint256 bits = _claimedBits[epochId][msg.sender];
        if (bits & bit != 0) revert AlreadyClaimed(); // INV-8
        _claimedBits[epochId][msg.sender] = bits | bit; // effects before external mint

        // R-19 hard cap: cumulative claims can never exceed the funded total (== emitted). Even a
        // root whose leaves over-sum cannot mint esFERA beyond the envelope the controller funded.
        uint256 claimed = claimedOf[epochId] + amount;
        if (claimed > totalEsFeraOf[epochId]) revert ExceedsEmitted();
        claimedOf[epochId] = claimed;

        esFera.mintAndVest(msg.sender, amount); // pays out as vesting esFERA
        emit Claimed(epochId, msg.sender, kind, amount);
    }

    /// @inheritdoc IDistributor
    function isClaimed(uint256 epochId, address account, uint8 kind) external view returns (bool) {
        return _claimedBits[epochId][account] & (1 << kind) != 0;
    }

    /// @inheritdoc IDistributor
    function rootOf(uint256 epochId) external view returns (bytes32) {
        return _root[epochId];
    }
}
