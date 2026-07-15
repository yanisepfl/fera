// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IAnchorStaking
/// @notice sFERA staking — the SIMPLE model (founder decision, v3.4): stake FERA → earn a pro-rata
///         share of the stakers' 50% protocol revenue leg, continuously (MasterChef accumulator).
///         Power = staked amount, FLAT — no boost, no lock-weeks, no decay, no end date. The ONLY
///         time element is a 7-day unstake cooldown re-armed by each stake (anti reward-JIT).
///         No voting/gauges. MASTER_SPEC §3, §6, §7, SHARED_CONTEXT §8.
interface IAnchorStaking {
    // ── Events (frozen, MASTER_SPEC §6) ──────────────────────────────────────────────────
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RevenueShareClaimed(address indexed account, address indexed token, uint256 amount);
    /// @notice Emitted when the esFERA instant-exit forfeit stakers-third is booked into the FERA
    ///         reward accumulator (REC-8). `booked` includes any forfeit FERA that had been held while
    ///         totalStaked was 0 and is now distributed.
    event ForfeitShareNotified(uint256 booked);

    error ZeroAmount();
    /// @notice Unstake attempted before the 7-day cooldown since the account's LAST stake elapsed.
    error StillLocked();
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

    /// @notice Stake `amount` FERA. Power is FLAT (= staked amount); revenue accrues continuously
    ///         pro-rata. Each stake (including top-ups) re-arms the caller's 7-day unstake cooldown
    ///         on their WHOLE balance — the anti reward-JIT guard.
    function stake(uint256 amount) external;

    /// @notice Unstake `amount` FERA once the 7-day cooldown since the caller's last stake elapsed.
    function unstake(uint256 amount) external;

    /// @notice Timestamp from which `account` may unstake (lastStakeTs + UNSTAKE_COOLDOWN_SEC).
    function unstakeAvailableAt(address account) external view returns (uint256);

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

    // NOTE (v3.4): `boostOf` was REMOVED with the boost concept itself. Deleting the boost also
    // closes INV-13 / PT-2 by design — the wash-farming vector existed ONLY under a >1x self-boost;
    // at flat pro-rata power, wash-farming is net-negative by arithmetic (SHARED_CONTEXT).

    /// @notice Total staked FERA (basis for the 50% revenue-share pro-rata).
    function totalStaked() external view returns (uint256);

    /// @notice Whether `token` is on the curated reward-token allowlist (REC-6/REC-7). Consulted by
    ///         FeraVault's v3.1 unified fee-routing (contracts/VAULT_STRATEGY_V3.md §9) to decide
    ///         whether a pool's native/quote tokens are already liquid reward assets (no-swap path)
    ///         or whether the native side needs a bounded self-swap into the quote asset first.
    function isRewardToken(address token) external view returns (bool);
}
