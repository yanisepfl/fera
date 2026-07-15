// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IAnchorStaking} from "./interfaces/IAnchorStaking.sol";
import {IRevenueDistributor} from "./interfaces/IRevenueDistributor.sol";
import {FeraConstants} from "./libraries/FeraConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AnchorStaking (sFERA)
/// @notice The SIMPLE staking model (founder decision, v3.4): stake FERA → earn a pro-rata share of
///         the stakers' 50% revenue leg (via RevenueDistributor) plus the stakers-third of esFERA
///         instant-exit forfeits, CONTINUOUSLY (MasterChef accumulator — no epochs, no lumps to
///         snipe). Power = staked amount, FLAT: no boost, no lock-weeks, no decaying multiplier
///         points, no end date. The ONLY time element is a 7-day unstake cooldown re-armed by every
///         stake — so reward-JIT (stake just before revenue, exit right after) can never work.
///         No voting, no gauges. "Stake FERA, earn revenue every second, unstake with 7 days' notice."
/// @dev    v3.4 removed the variable lock-weeks boost entirely. That also CLOSES INV-13 / PT-2 by
///         design: the wash-farming vector required a >1x self-boost; at flat pro-rata power it is
///         net-negative by arithmetic (SHARED_CONTEXT). esFERA (the 6-month emission escrow) is a
///         separate, orthogonal system — it never was and is not staking power.
contract AnchorStaking is IAnchorStaking, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 public immutable fera;
    IRevenueDistributor public immutable revenueDistributor;

    /// @dev Reward-accumulator fixed-point scale (MasterChef PREC).
    uint256 internal constant ACC_PRECISION = 1e18;

    /// @dev Hard cap on the reward-token allowlist (REC-7). Revenue is a small fixed set (FERA + a
    ///      couple of stables/WETH), so 16 is comfortable headroom; the cap bounds the O(n) stake/unstake
    ///      loops (`_harvestAll`/`_settleAll`/`_syncDebtAll`). `addRewardToken` reverts past the cap, and
    ///      only the reward admin can add — so the set can never be griefer-inflated (the crowd-out DoS
    ///      that a permissionless register-at-notify + this cap would have allowed).
    uint256 public constant MAX_REWARD_TOKENS = 16;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;
    /// @dev Timestamp of the account's LAST stake. Unstaking requires `now >= lastStakeTs + 7d`
    ///      (FeraConstants.UNSTAKE_COOLDOWN_SEC) — the single anti reward-JIT guard. A top-up
    ///      re-arms the clock on the WHOLE balance (conservative by design, documented in the UI).
    mapping(address => uint256) public lastStakeTs;

    /// @dev Reward accumulator per token, scaled by ACC_PRECISION. accPerShare grows as revenue is
    ///      harvested; a staker's entitlement is `shares·accPerShare/PREC − rewardDebt`.
    mapping(address => uint256) public accPerShare;
    mapping(address => mapping(address => uint256)) internal _rewardDebt; // [token][account]
    /// @dev Settled-but-unclaimed rewards captured when a staker changes their share (R-21). Without
    ///      this, stake/unstake never re-based rewardDebt and a late staker could claim historical
    ///      accPerShare, stealing prior stakers' accrued revenue.
    mapping(address => mapping(address => uint256)) internal _claimable; // [token][account]

    /// @dev Enumerable ALLOWLIST of reward tokens, curated by `rewardTokenAdmin` (REC-6/REC-7). The
    ///      canonical revenue set (FERA + the stables/WETH) is added at config time — BEFORE revenue
    ///      flows — so stake/unstake always settle every real reward token BEFORE a share change, closing
    ///      the R-21 dilution window (REC-6) without any permissionless registration path. Permissionless
    ///      registration was REMOVED: it let a griefer fund dust of 16 junk tokens through the open
    ///      `RevenueDistributor.notifyRevenue` to fill this capped set and PERMANENTLY strand legitimate
    ///      staker revenue (crowd-out), or register a transfer-reverting token to brick every
    ///      stake/unstake (poison). Bounded by MAX_REWARD_TOKENS (REC-7).
    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;

    /// @notice Governance address permitted to curate the reward-token allowlist (REC-6/REC-7).
    ///         Immutable; expected to be the same 48h Treasury timelock that owns the other contracts.
    ///         Its ONLY power is adding a revenue token to the capped set — it cannot touch stakes,
    ///         accounting, or anyone's ability to unstake.
    address public immutable rewardTokenAdmin;

    /// @notice The ONLY address allowed to book the esFERA forfeit stakers-third (EsFera). Set once by
    ///         governance at config time (write-once). Gating to a trusted caller keeps `notifyForfeitShare`
    ///         a pure accPerShare[FERA] increment — no balance-delta guard needed — since EsFera always
    ///         transfers the FERA in immediately before the call (REC-8).
    address public forfeitNotifier;

    /// @notice Forfeit FERA received while `totalStaked == 0` (or before FERA was allowlisted), held for
    ///         distribution and folded into `accPerShare[FERA]` on the next harvest / notify once stakers
    ///         exist (REC-8). Physically present in this contract's FERA balance the whole time.
    uint256 public pendingForfeitFera;

    /// @dev Zero-address guard on the immutable reward-token admin (governance sets it at deploy).
    error ZeroAddress();

    constructor(IERC20 fera_, IRevenueDistributor revenueDistributor_, address rewardTokenAdmin_) {
        if (rewardTokenAdmin_ == address(0)) revert ZeroAddress();
        fera = fera_;
        revenueDistributor = revenueDistributor_;
        rewardTokenAdmin = rewardTokenAdmin_;
    }

    /// @inheritdoc IAnchorStaking
    /// @dev nonReentrant: the isolated `harvestReward` self-calls and per-token `pull`s make external
    ///      transfers before the share change — the guard neutralizes any callback-token re-entry.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // R-21: settle first, THEN change the share. Order matters — harvest into accPerShare on the
        // OLD totalStaked (so pre-stake revenue is not diluted to the new staker), credit the caller's
        // pending on their OLD shares, then re-base rewardDebt to the NEW shares below.
        _harvestAll();
        _settleAll(msg.sender, stakedOf[msg.sender]);

        fera.safeTransferFrom(msg.sender, address(this), amount);
        stakedOf[msg.sender] += amount;
        totalStaked += amount;

        _syncDebtAll(msg.sender, stakedOf[msg.sender]);
        // Anti reward-JIT: every stake (incl. top-ups) re-arms the 7-day unstake cooldown on the
        // caller's WHOLE balance. Conservative by design; documented in the UI.
        lastStakeTs[msg.sender] = block.timestamp;
        emit Staked(msg.sender, amount);
    }

    /// @inheritdoc IAnchorStaking
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < lastStakeTs[msg.sender] + FeraConstants.UNSTAKE_COOLDOWN_SEC) revert StillLocked();
        // R-21: settle accrued rewards on current shares BEFORE shrinking the stake, then re-base
        // rewardDebt to the reduced shares. An unstaker keeps exactly what accrued while staked and
        // can never underflow prior stakers' balances.
        _harvestAll();
        _settleAll(msg.sender, stakedOf[msg.sender]);

        stakedOf[msg.sender] -= amount;
        totalStaked -= amount;

        _syncDebtAll(msg.sender, stakedOf[msg.sender]);
        fera.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @inheritdoc IAnchorStaking
    /// @dev Only allowlisted tokens accrue (see `_harvest`); a non-allowlisted `token` harvests nothing
    ///      and returns 0. Harvesting a single token directly may revert if that token itself reverts on
    ///      transfer (e.g. a blacklisted stable) — that only blocks claiming THAT token, never
    ///      stake/unstake (which isolate each token, see `_harvestAll`).
    function claimRevenueShare(address token) external nonReentrant returns (uint256 amount) {
        _harvest(token); // pull this contract's 50% from RevenueDistributor into the accumulator
        _settle(token, msg.sender, stakedOf[msg.sender]); // credit newly-accrued into _claimable
        _syncDebt(token, msg.sender, stakedOf[msg.sender]); // debt now matches shares·accPerShare

        amount = _claimable[token][msg.sender];
        if (amount != 0) {
            _claimable[token][msg.sender] = 0;
            IERC20(token).safeTransfer(msg.sender, amount);
            emit RevenueShareClaimed(msg.sender, token, amount);
        }
    }

    /// @notice Rewards claimable right now for `account` in `token` (settled + not-yet-settled).
    function claimableRevenue(address account, address token) external view returns (uint256) {
        uint256 accrued = (stakedOf[account] * accPerShare[token]) / ACC_PRECISION;
        uint256 debt = _rewardDebt[token][account];
        uint256 pendingAccrual = accrued > debt ? accrued - debt : 0;
        return _claimable[token][account] + pendingAccrual;
    }

    /// @notice Number of reward tokens on the allowlist.
    function rewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    /// @inheritdoc IAnchorStaking
    /// @dev REC-6/REC-7 allowlist. Governance adds the canonical revenue tokens (FERA + the stables/WETH)
    ///      at config time, BEFORE revenue flows — so every real reward token is settled on every
    ///      stake/unstake from the start (no R-21 dilution window) WITHOUT a permissionless registration
    ///      path a griefer could abuse to crowd out the capped set or poison the harvest loop. Bounded by
    ///      MAX_REWARD_TOKENS (REC-7).
    function addRewardToken(address token) external {
        if (msg.sender != rewardTokenAdmin) revert NotRewardAdmin();
        if (token == address(0) || isRewardToken[token]) revert InvalidRewardToken();
        if (rewardTokens.length >= MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        isRewardToken[token] = true;
        rewardTokens.push(token);
    }

    /// @inheritdoc IAnchorStaking
    /// @dev Write-once forfeit-notifier wiring (REC-8). onlyRewardTokenAdmin; EsFera is not known at
    ///      construction (it takes THIS address in its ctor), so it is wired post-deploy by governance.
    function setForfeitNotifier(address notifier) external {
        if (msg.sender != rewardTokenAdmin) revert NotRewardAdmin();
        if (notifier == address(0) || forfeitNotifier != address(0)) revert ForfeitNotifierAlreadySet();
        forfeitNotifier = notifier;
    }

    /// @inheritdoc IAnchorStaking
    /// @dev REC-8: EsFera transfers the forfeit stakers-third FERA to this contract, then calls this to
    ///      book it into the FERA reward accumulator so stakers accrue it pro-rata (INV-9's stakers leg
    ///      is now actually distributed, not stranded). Gated to the forfeit notifier so the increment
    ///      is trusted — the FERA is always transferred in first, so no balance-delta guard is needed.
    ///      NEVER reverts for the correct caller (it must not be able to brick an instant-exit): if
    ///      there are no stakers yet, or FERA is not yet an allowlisted reward token, the amount is HELD
    ///      in `pendingForfeitFera` and folded in on the next harvest once those conditions hold.
    function notifyForfeitShare(uint256 amount) external {
        if (msg.sender != forfeitNotifier) revert NotForfeitNotifier();
        uint256 bookable = amount + pendingForfeitFera;
        if (bookable == 0) return;
        // Hold until there are shares to divide by AND FERA is a settled reward token (else the fold
        // below would credit an accumulator the stake/unstake settle loops don't iterate).
        if (totalStaked == 0 || !isRewardToken[address(fera)]) {
            pendingForfeitFera = bookable;
            return;
        }
        pendingForfeitFera = 0;
        accPerShare[address(fera)] += (bookable * ACC_PRECISION) / totalStaked;
        emit ForfeitShareNotified(bookable);
    }

    /// @notice Permissionless "poke" that folds any pending `token` revenue into the accumulator. Also
    ///         the isolation boundary for `_harvestAll`: it is invoked via an external self-call inside
    ///         try/catch so that a single reward token which reverts on transfer (e.g. a stable that
    ///         blacklists this contract) can be SKIPPED instead of bricking every stake/unstake and
    ///         locking all staked principal. `onlySelf`-when-looping is not required — harvesting is a
    ///         benign, value-neutral operation (it only distributes already-owed revenue to current
    ///         stakers), so exposing it publicly is safe and useful.
    function harvestReward(address token) public {
        _harvest(token);
    }

    // ── MasterChef accounting internals (R-21) ────────────────────────────────────────────

    /// @dev Pull any pending `token` revenue owed to stakers and fold it into accPerShare, using the
    ///      CURRENT totalStaked so revenue is only ever divided among shares that existed when it was
    ///      harvested. Only ALLOWLISTED tokens accrue (REC-6/REC-7) — a non-allowlisted token is ignored
    ///      so its pending is never pulled into an accumulator the settle/debt loops don't cover.
    function _harvest(address token) internal {
        if (totalStaked == 0 || !isRewardToken[token]) return;
        // REC-8: fold any forfeit FERA that arrived while there were no stakers (or before FERA was
        // allowlisted) now that both conditions hold. It is already in this contract's FERA balance.
        if (token == address(fera) && pendingForfeitFera != 0) {
            uint256 held = pendingForfeitFera;
            pendingForfeitFera = 0;
            accPerShare[token] += (held * ACC_PRECISION) / totalStaked;
            emit ForfeitShareNotified(held);
        }
        uint256 pendingAmt = revenueDistributor.pending(address(this), token);
        if (pendingAmt == 0) return;
        uint256 pulled = revenueDistributor.pull(token);
        accPerShare[token] += (pulled * ACC_PRECISION) / totalStaked;
    }

    /// @dev Harvest every allowlisted reward token before a share change so all accumulators are current
    ///      on the OLD totalStaked. Each token is harvested through an ISOLATED external self-call: if
    ///      one token reverts on its transfer (blacklisted/paused stable), it is skipped rather than
    ///      reverting the whole stake/unstake — staked principal can always exit (a hardening beyond the
    ///      allowlist, since even a curated stable can later blacklist this contract). A skipped token's
    ///      revenue simply waits for the next successful harvest.
    function _harvestAll() internal {
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            try this.harvestReward(rewardTokens[i]) {} catch {}
        }
    }

    /// @dev Credit `account`'s accrued-but-unsettled reward for `token` into _claimable, based on
    ///      `shares`. Does NOT touch rewardDebt (re-synced after the share change via _syncDebt).
    function _settle(address token, address account, uint256 shares) internal {
        uint256 accrued = (shares * accPerShare[token]) / ACC_PRECISION;
        uint256 debt = _rewardDebt[token][account];
        if (accrued > debt) _claimable[token][account] += accrued - debt;
    }

    function _settleAll(address account, uint256 shares) internal {
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            _settle(rewardTokens[i], account, shares);
        }
    }

    /// @dev Re-base `account`'s rewardDebt for `token` to `shares·accPerShare` so future accrual is
    ///      measured from now. This is the line the old code omitted on stake/unstake (R-21).
    /// @dev DF-8: the debt baseline is rounded UP (ceil), while accrual (`_settle`/`claimableRevenue`)
    ///      is floored — so a staker's credited reward per settled segment is
    ///      `floor(shares·A_now/PREC) − ceil(shares·A_sync/PREC) ≤ shares·(A_now−A_sync)/PREC`, the exact
    ///      pro-rata integral. Summing over all stakers present at a harvest gives
    ///      `Σ shares_i·d/PREC = totalStaked·d/PREC ≤ pulled` (since `d = floor(pulled·PREC/totalStaked)`),
    ///      so Σ owed can never exceed Σ pulled — per-token solvency ALWAYS holds and ≤1 wei/segment of
    ///      rounding dust is stranded in-contract (against the claimant), never over-credited. Flooring the
    ///      debt (the pre-fix behaviour) let a mid-stream joiner under-charge their baseline and claim a
    ///      shared rounding-boundary carry, over-distributing by up to (nStakers−1) wei (StakingMultiReward
    ///      invariant, rewardConservation/rewardSolvent). ceil(0)==0, so a from-genesis staker is unaffected.
    function _syncDebt(address token, address account, uint256 shares) internal {
        _rewardDebt[token][account] = shares.mulDiv(accPerShare[token], ACC_PRECISION, Math.Rounding.Ceil);
    }

    function _syncDebtAll(address account, uint256 shares) internal {
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            _syncDebt(rewardTokens[i], account, shares);
        }
    }

    /// @inheritdoc IAnchorStaking
    function unstakeAvailableAt(address account) external view returns (uint256) {
        return lastStakeTs[account] + FeraConstants.UNSTAKE_COOLDOWN_SEC;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // INV-13 / PT-2 — CLOSED BY DESIGN (v3.4 staking simplification, founder decision).
    // The wash-farming vector (PT-2: a self-dealing whale over-collecting honest users' emission
    // share) existed ONLY under a >1x self-boost. The boost concept was REMOVED entirely — power is
    // flat pro-rata staked FERA — so SHARED_CONTEXT's "wash-farming net-negative by arithmetic" now
    // holds unconditionally and there is no vulnerable path left to gate. The former `boostOf()`
    // stub and `_inv13SelfMatchExcluded` hook were deleted with it. If a loyalty boost is ever
    // reintroduced (one fixed 6-month lock at a constant multiplier is the only shape considered),
    // INV-13 (a+b) must be re-satisfied FIRST: (a) no boost on self-generated/self-LP'd flow;
    // (b) the INV-7 emission cap applies AFTER boost weighting (redistribute, never boost-then-mint).
    // ═══════════════════════════════════════════════════════════════════════════════════════
}
