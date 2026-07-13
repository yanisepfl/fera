// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IRevenueDistributor
/// @notice Immutable 50/25/25 pull-based split (stakers / treasury / ops). No rounding dust may
///         escape accounting (INV-10). MASTER_SPEC §3, §6, §7.
interface IRevenueDistributor {
    // ── Events (frozen, MASTER_SPEC §6) ──────────────────────────────────────────────────
    event RevenueReceived(address indexed token, uint256 amount);
    event RevenueSplit(address indexed token, uint256 toStakers, uint256 toTreasury, uint256 toOps);

    error ZeroAddress();
    error NothingToPull();
    /// @notice notifyRevenue was called crediting more than the contract's real, unclaimed holdings
    ///         back — i.e. the `amount` was not actually transferred in (R-22 pull-DoS guard).
    error UnbackedRevenue();

    /// @notice Account a received `amount` of `token` (already transferred in) and split it
    ///         50/25/25 into pull-balances. Remainder-to-last so nothing escapes (INV-10).
    function notifyRevenue(address token, uint256 amount) external;

    /// @notice Pull the caller's (staker-router / treasury / ops) accrued balance of `token`.
    function pull(address token) external returns (uint256 amount);

    /// @notice Pending pull-balance for `who` in `token`.
    function pending(address who, address token) external view returns (uint256);
}
