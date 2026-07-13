// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IEmissionsController
/// @notice Weekly epoch clock; holds the 90% unemitted FERA; computes each epoch's emission as
///         `min(cap(t), β × revenueValuedInFera)` and funds the Distributor in esFERA (INV-7).
///         MASTER_SPEC §3, §6, §7, §9.
interface IEmissionsController {
    // ── Events (frozen, MASTER_SPEC §6) ──────────────────────────────────────────────────
    event EpochFinalized(
        uint256 indexed epochId, uint256 capAmount, uint256 revenueBound, uint256 emitted, uint256 feraTwap
    );
    /// @notice Emitted when the timelock rotates the emissions keeper (§10 redundant keepers).
    event KeeperUpdated(address indexed keeper);

    error EpochNotOver();
    error EpochAlreadyFinalized();
    error EmissionBoundExceeded();
    error OnlyKeeper();
    error ZeroAddress();

    /// @notice Current epoch index (from 0), advancing every EPOCH_LENGTH.
    function currentEpoch() external view returns (uint256);

    /// @notice Timestamp at which `epochId` ends.
    function epochEnd(uint256 epochId) external view returns (uint256);

    /// @notice Logistic supply cap for the epoch containing timestamp `t` (S-curve, ~4y horizon).
    /// @dev    TODO(spec-freeze): PARAMS.md#cap_logistic_{L,k,t0}.
    function capAt(uint256 t) external view returns (uint256);

    /// @notice Finalize `epochId`: fund EXACTLY `emissionRequested` (the pipeline's Σ leaf total,
    ///         ΣE_p, carried by the keeper from the reproducibility bundle — D-BK-12), enforcing
    ///         `emissionRequested ≤ min(cap, β×revenueValuedInFera)` (INV-7, an inequality). Mints
    ///         that FERA as esFERA backing and records `emittedOf[epochId]` so the Distributor can
    ///         assert `totalEsFera == emittedOf` at postRoot (R-19 / D-M9 C2). Emits EpochFinalized.
    /// @param epochId          epoch to finalize (must be over and not already finalized)
    /// @param emissionRequested the pipeline's committed epoch emission total (Σ leaf amounts)
    /// @param revenueValuedInFera  epoch protocol revenue converted at manipulation-capped TWAP
    /// @param feraTwap         the TWAP used (recorded for transparency/reproducibility)
    function finalizeEpoch(uint256 epochId, uint256 emissionRequested, uint256 revenueValuedInFera, uint256 feraTwap)
        external
        returns (uint256 emitted);

    /// @notice The FERA amount actually funded/minted for `epochId` (0 if not finalized). The
    ///         Distributor binds the posted Merkle total to this (R-19 on-chain envelope check).
    function emittedOf(uint256 epochId) external view returns (uint256);

    /// @notice Whether `epochId` has been finalized (distinguishes "funded 0" from "not funded").
    function finalized(uint256 epochId) external view returns (bool);

    /// @notice The emission bound β (1e18-fixed). Timelocked. Default 0.8e18. Hard on-chain cap 0.9.
    function beta() external view returns (uint256);
}
