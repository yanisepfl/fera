// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IAnchorStaking
/// @notice sFERA staking: stake FERA, ≤2x boost on own emissions, multiplier points with linear
///         decay, receives 50% protocol revenue share + staker forfeit share. No voting/gauges.
///         MASTER_SPEC §3, §6, §7, SHARED_CONTEXT §8.
interface IAnchorStaking {
    // ── Events (frozen, MASTER_SPEC §6) ──────────────────────────────────────────────────
    event Staked(address indexed account, uint256 amount, uint256 lockWeeks);
    event Unstaked(address indexed account, uint256 amount);
    event RevenueShareClaimed(address indexed account, address indexed token, uint256 amount);
    /// @notice Emitted when the esFERA instant-exit forfeit stakers-third is booked into the FERA
    ///         reward accumulator (REC-8). `booked` includes any forfeit FERA that had been held while
    ///         totalStaked was 0 and is now distributed.
    event ForfeitShareNotified(uint256 booked);

    error ZeroAmount();
    error StillLocked();
    error BoostOutOfBounds();
    /// @notice addRewardToken caller was not the reward-token admin (REC-6/REC-7 allowlist).
    error NotRewardAdmin();
    /// @notice addRewardToken with the zero address or an already-registered token.
    error InvalidRewardToken();
    /// @notice addRewardToken would exceed MAX_REWARD_TOKENS — the hard loop bound (REC-7).
    error TooManyRewardTokens();
    /// @notice notifyForfeitShare caller was not the immutable-once forfeit notifier (EsFera) (REC-8).
    error NotForfeitNotifier();
    /// @notice setForfeitNotifier called with the zero address, or after it was already set (REC-8).
    error ForfeitNotifierAlreadySet();

    /// @notice Stake `amount` FERA, optionally time-locking for `lockWeeks` (decaying multiplier
    ///         points). Mints sFERA position accounting.
    function stake(uint256 amount, uint256 lockWeeks) external;

    /// @notice Unstake `amount` FERA once any lock has elapsed.
    function unstake(uint256 amount) external;

    /// @notice Claim the caller's accrued revenue share in `token` (from RevenueDistributor +
    ///         esFERA forfeit stakers-third).
    function claimRevenueShare(address token) external returns (uint256 amount);

    /// @notice Add `token` to the reward-token allowlist (REC-6/REC-7). Callable ONLY by the immutable
    ///         reward-token admin (governance). The canonical revenue set (FERA + the stables/WETH) is
    ///         added at config time — before revenue flows — so stake/unstake always settle every real
    ///         reward token before a share change (closes the R-21 dilution residual, REC-6) WITHOUT a
    ///         permissionless registration path a griefer could use to crowd out or poison the capped
    ///         set (REC-7). Reverts past MAX_REWARD_TOKENS, on the zero address, or on a duplicate.
    function addRewardToken(address token) external;

    /// @notice Book `amount` of FERA (already transferred in) as a distributable staker reward — the
    ///         esFERA instant-exit forfeit stakers-third (REC-8 / INV-9). Callable ONLY by the forfeit
    ///         notifier (EsFera), set once by governance. Folds into the FERA reward accumulator so
    ///         current stakers accrue it pro-rata; if there are no stakers yet (or FERA is not yet an
    ///         allowlisted reward token) it is HELD and folded in on the next harvest, so the call never
    ///         reverts and can never brick an instant-exit. FERA MUST be `addRewardToken`'d for stakers
    ///         to accrue it (deployment dependency, documented).
    function notifyForfeitShare(uint256 amount) external;

    /// @notice Set the forfeit notifier (EsFera) once, at config time. onlyRewardTokenAdmin; the
    ///         address is write-once (reverts if already set or zero). Deployment wires EsFera here so
    ///         its forfeit stakers-third can be booked (REC-8).
    function setForfeitNotifier(address notifier) external;

    /// @notice Boost multiplier (1e18-fixed, capped at ~2x) applied to `account`'s own
    ///         trader/LP emissions. Read by the off-chain emissions pipeline (§9).
    function boostOf(address account) external view returns (uint256 boostWad);

    /// @notice Total staked FERA (basis for the 50% revenue-share pro-rata).
    function totalStaked() external view returns (uint256);
}
