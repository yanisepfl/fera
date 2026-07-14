// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IGenesisVesting
/// @notice Single-beneficiary, single-token lock for the 10% FERA genesis allocation
///         (100,000,000 FERA). Standard shape: 1-YEAR CLIFF, then LINEAR VESTING over the
///         following 3 YEARS (4-year total horizon — contracts/VAULT_STRATEGY_V3.md §10).
///         Nothing is claimable before the cliff; after it, `claimable = total *
///         (elapsed - cliff) / (totalDuration - cliff)`, monotonic non-decreasing, never
///         exceeding `total`.
interface IGenesisVesting {
    /// @notice Emitted whenever `claim()` releases FERA to the beneficiary.
    event Released(uint256 amount);

    /// @notice `claim()` was called while `releasable() == 0` (before the cliff, or nothing new
    ///         vested since the last claim).
    error NothingToClaim();

    error ZeroAddress();

    /// @notice The FERA token being vested (immutable — this contract vests exactly one token).
    function token() external view returns (IERC20);

    /// @notice The sole recipient of all released FERA (immutable — no re-beneficiary path).
    function beneficiary() external view returns (address);

    /// @notice Vesting clock start (== deploy time).
    function start() external view returns (uint64);

    /// @notice Cumulative FERA already released to the beneficiary via `claim()`.
    function released() external view returns (uint256);

    /// @notice Total vested-by-schedule at `timestamp` (capped at the total allocation, 0 before
    ///         the cliff). `total` is read live as `token.balanceOf(this) + released` so the
    ///         schedule is exact regardless of when the genesis mint physically lands.
    function vestedAmount(uint256 timestamp) external view returns (uint256);

    /// @notice Currently claimable FERA: `vestedAmount(block.timestamp) - released`.
    function releasable() external view returns (uint256);

    /// @notice Release all currently-vested-and-unclaimed FERA to `beneficiary`. Permissionless-
    ///         pull: ANY caller may trigger it, but funds always land at the fixed `beneficiary` —
    ///         never at `msg.sender` — so permissionless triggering carries no fund-safety risk.
    ///         Reverts `NothingToClaim` if `releasable() == 0`.
    function claim() external returns (uint256 amount);
}
