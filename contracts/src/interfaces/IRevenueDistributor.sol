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

    /// @notice v3.1 unified fee-routing (contracts/VAULT_STRATEGY_V3.md §9) NO-STAKER ROUTING:
    ///         identical accounting/partition to `notifyRevenue`, except the stakers' 50% leg is
    ///         folded into treasury instead (toStakers=0, toTreasury+=50%). Used by FeraVault ONLY
    ///         when it has determined (via AnchorStaking.totalStaked()) that nobody is staked yet —
    ///         crediting the stakers' pending balance in that state would sit as an unclaimed
    ///         windfall for whoever stakes first, rather than a fair pro-rata reward for time
    ///         actually staked. Still exact (INV-10): toStakers + toTreasury + toOps == amount.
    function notifyRevenueNoStakers(address token, uint256 amount) external;

    /// @notice Pull the caller's (staker-router / treasury / ops) accrued balance of `token`.
    function pull(address token) external returns (uint256 amount);

    /// @notice Pending pull-balance for `who` in `token`.
    function pending(address who, address token) external view returns (uint256);

    /// @notice The immutable stakers-leg recipient (AnchorStaking, 50%).
    function stakers() external view returns (address);

    /// @notice The immutable treasury-leg recipient (25%, also the v3.1 in-kind-fallback sink).
    function treasury() external view returns (address);

    /// @notice The immutable ops-leg recipient (25%).
    function ops() external view returns (address);
}
