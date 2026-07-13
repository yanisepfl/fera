// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IDistributor
/// @notice Per-epoch Merkle-root registry; pull claims paid in esFERA; double-claim-proof (INV-8).
///         Leaf = keccak256(abi.encode(epochId, account, kind, amount)); OZ sorted-pair MerkleProof.
///         MASTER_SPEC §3, §6, §9.
interface IDistributor {
    // ── Events (frozen, MASTER_SPEC §6) ──────────────────────────────────────────────────
    event RootPosted(uint256 indexed epochId, bytes32 merkleRoot, uint256 totalEsFera);
    event Claimed(uint256 indexed epochId, address indexed account, uint8 kind, uint256 amount);
    // kind: 0=traderRebate 1=lpReward

    error RootAlreadyPosted();
    error RootNotPosted();
    error AlreadyClaimed();
    error InvalidProof();
    error OnlyRootPoster();
    /// @notice postRoot for an epoch the EmissionsController has not finalized/funded (R-19).
    error EpochNotFinalized();
    /// @notice Posted totalEsFera != the FERA the controller funded for the epoch (R-19 envelope).
    error EmittedMismatch();
    /// @notice Cumulative claims for an epoch would exceed the funded total (R-19 hard cap).
    error ExceedsEmitted();

    /// @notice Post the epoch's Merkle root (one per epoch, immutable once set). Keeper-only.
    /// @param totalEsFera  total esFERA the root distributes (== Σ leaf amounts per the §9 bundle).
    /// @dev    Reverts unless the epoch is finalized AND `totalEsFera == controller.emittedOf(epoch)`
    ///         — binds a compromised root-poster to the funded envelope (R-19 / D-M9 C2).
    function postRoot(uint256 epochId, bytes32 merkleRoot, uint256 totalEsFera) external;

    /// @notice Claim `amount` esFERA for (epochId, msg.sender, kind) against the posted root.
    ///         Reverts on bad proof or if already claimed (INV-8).
    function claim(uint256 epochId, uint8 kind, uint256 amount, bytes32[] calldata proof) external;

    /// @notice Whether (epochId, account, kind) has been claimed. Backed by a per-epoch bitmap.
    function isClaimed(uint256 epochId, address account, uint8 kind) external view returns (bool);

    /// @notice The posted root for `epochId` (bytes32(0) if none).
    function rootOf(uint256 epochId) external view returns (bytes32);
}
