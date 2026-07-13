// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IEsFera
/// @notice Non-transferable escrowed FERA. All emissions arrive as esFERA; ~6-month linear vest
///         to FERA 1:1; 50% instant-exit haircut; forfeiture routed 1/3 burn / 1/3 stakers /
///         1/3 RevenueDistributor (INV-9). MASTER_SPEC §3, §6, §7.
interface IEsFera {
    // ── Events (frozen, MASTER_SPEC §6 + F-8/F-9 batch: VestClaimed) ─────────────────────
    event VestStarted(address indexed account, uint256 amount, uint256 startTs, uint256 endTs);
    event InstantExit(address indexed account, uint256 esBurned, uint256 feraOut, uint256 haircut);
    event ForfeitRouted(uint256 burned, uint256 toStakers, uint256 toRevenue);
    /// @notice Emitted when vested FERA is claimed (D-BK-9 / F-9 — lets the indexer distinguish
    ///         claimable from vested-and-withdrawn). EXACT signature per MASTER_SPEC §6 v0.4 batch.
    event VestClaimed(address indexed account, uint256 amount);

    error NonTransferable();
    error OnlyMinter();
    error NothingVesting();
    error ZeroAmount();
    /// @notice mintAndVest would open a vest not covered by FERA backing (SEC-3 #8 / audit).
    error Undercollateralized();

    /// @notice A single vesting position (linear from startTs→endTs, claimable pro-rata).
    /// @dev    `amount` is the IMMUTABLE original grant — it is never mutated after creation, so the
    ///         linear schedule `vestedByTime = amount·elapsed/dur` is stable (R-20 fix). FERA leaves
    ///         a grant via two disjoint accumulators: `claimed` (vested principal withdrawn via
    ///         claimVested) and `exited` (still-locked principal removed early via instantExit).
    ///         Conservation invariant: `claimed + exited ≤ amount` ALWAYS — a grant can never release
    ///         more FERA than was minted for it.
    struct Vest {
        uint256 amount; // IMMUTABLE original esFERA granted (never shrunk — R-20)
        uint256 claimed; // FERA claimed via claimVested (from the vested portion)
        uint256 exited; // locked principal removed early via instantExit (haircut path)
        uint64 startTs;
        uint64 endTs;
    }

    /// @notice Mint esFERA to `account` and open a vest. Callable only by authorized minters
    ///         (Distributor for claims; EmissionsController where applicable).
    function mintAndVest(address account, uint256 amount) external;

    /// @notice Claim the linearly-vested FERA accrued so far across the caller's vests.
    function claimVested() external returns (uint256 feraOut);

    /// @notice Instant-exit `amount` of esFERA now, taking the 50% haircut. Emits InstantExit
    ///         then ForfeitRouted (burn/stakers/revenue thirds). Value-conserving (INV-9).
    function instantExit(uint256 amount) external returns (uint256 feraOut);

    /// @notice Total FERA claimable right now for `account` across all vests.
    function claimable(address account) external view returns (uint256);
}
