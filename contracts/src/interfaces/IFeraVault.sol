// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FeraTypes} from "../libraries/FeraTypes.sol";

/// @title IFeraVault (v3 — base+limit+idle is the ONLY strategy; contracts/VAULT_STRATEGY_V3.md)
/// @notice The managed-liquidity layer. `createBaseLimitPool` builds, per pool, TWO risk tranches
///         (Steady/Active), each an independent ERC-20 share class over a DISJOINT band set
///         (INV-15): a wide vol-adaptive BASE band, an on-demand inventory-skewed LIMIT band, and
///         an explicit IDLE reserve. Deposits are ratio-matched + TWAP-gated + cooled-down (Gamma
///         hardening); fee collection skims exactly 10% per tranche (INV-3). The legacy Core/Mid/
///         Tail band-ladder + drip + INV-5″ guarded-recenter surface (`createPool`, `drip`,
///         `recenterMeme`, `pokeDepthBreach`, `recenter`, `widen`, `partialWithdraw`, `compound`) is
///         REMOVED — nothing was ever deployed, so there is no compatibility obligation.
///         v3.3 (contracts/VAULT_STRATEGY_V3.md §11): `createBaseLimitPool` is PERMISSIONLESS —
///         team-curation now happens via `allowedQuoteAssets` (quote-asset allowlist, both regimes)
///         and `approvedRwaFeeds` (RWA-only oracle-feed registry), plus the independent, team-only
///         `emissionsEligible` per-pool flag (off-chain esFERA emission attribution — never fee
///         generation/routing, which every pool participates in regardless of this flag).
///         MASTER_SPEC §3, §6 (F-8 batch: `uint8 tranche` fields).
interface IFeraVault {
    // ── Events (frozen MASTER_SPEC §6 + F-8 batch: `uint8 tranche` appended) ───────────────
    event Deposit(
        bytes32 indexed poolId,
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint256 sharesMinted,
        uint8 tranche
    );
    event Withdraw(
        bytes32 indexed poolId,
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint256 sharesBurned,
        uint8 tranche
    );
    event FeesCollected(
        bytes32 indexed poolId, uint256 fee0, uint256 fee1, uint256 perfFee0, uint256 perfFee1, uint8 tranche
    );
    /// @dev `kind` per `FeraTypes.StrategyKind` (0=initialMint, 7-12 the base+limit+idle actions;
    ///      1-6 are legacy values retained only so historical event decoding never shifts — no
    ///      current code path emits them). `oraclePrice` is a generic contextual scalar re-used
    ///      per-action (e.g. the IL budget for a base recenter); it is NOT always a price.
    event StrategyAction(
        bytes32 indexed poolId, uint8 kind, int24 tickLower, int24 tickUpper, uint256 oraclePrice, bytes32 justificationHash
    );
    event SharePriceCheckpoint(bytes32 indexed poolId, uint256 sharePriceX96, uint256 epochId, uint8 tranche); // INV-4
    /// @notice Emitted when the owner (timelock) rotates the strategy keeper.
    event KeeperUpdated(address indexed keeper);
    /// @notice Emitted when governance (timelock owner) toggles a whitelisted external rebalance
    ///         venue (router/pool the Vault may route a bounded rebalancing swap through).
    event VenueAllowed(address indexed venue, bool allowed);
    /// @notice Emitted when the tier / IDLE-buffer config of a (pool,tranche) changes.
    event TierConfigured(bytes32 indexed poolId, uint8 tranche, uint8 tier, uint16 idleBps);
    /// @notice A single-coin redemption (shares burned into ONE token within the slippage bound).
    event WithdrawSingle(bytes32 indexed poolId, address indexed user, address tokenOut, uint256 amountOut, uint256 sharesBurned, uint8 tranche);
    /// @notice v3: governance (timelocked owner) moved the vol-adaptive width-multiplier clamp band,
    ///         WITHIN the immutable [VOL_WIDTH_MULT_MIN_LEGAL_BPS, VOL_WIDTH_MULT_MAX_LEGAL_BPS] range.
    event VolWidthMultBoundsUpdated(uint256 minBps, uint256 maxBps);
    /// @notice v3.1 unified fee-routing (contracts/VAULT_STRATEGY_V3.md §9): a native-side perf fee
    ///         was bound-self-swapped into the pool's quote asset (the swap path — the no-swap and
    ///         fallback paths do NOT emit this).
    event PerfFeeSwapped(
        bytes32 indexed poolId, uint8 tranche, address nativeToken, uint256 nativeAmountIn, address quoteToken, uint256 quoteAmountOut
    );
    /// @notice v3.1 unified fee-routing: the bounded self-swap of a native-side perf fee either
    ///         exceeded the slippage bound or reverted for any other reason (hostile/thin pool,
    ///         reverting/fee-on-transfer native token) — the amount was forwarded IN-KIND, entirely
    ///         to treasury (never split 50/25/25). `forwarded` is false if even the raw fallback
    ///         transfer itself failed (an unconditionally-hostile token) — collectFees still did NOT
    ///         revert; the dust simply remains in the Vault's own balance in that case.
    event PerfFeeInKindFallback(bytes32 indexed poolId, uint8 tranche, address token, uint256 amount, bool forwarded);
    /// @notice v3.3 permissionless pool creation (contracts/VAULT_STRATEGY_V3.md §11): the team
    ///         (timelocked owner) toggled whether `token` may be used as a pool's QUOTE-side asset.
    event QuoteAssetAllowed(address indexed token, bool allowed);
    /// @notice v3.3: the team approved `feed` as a verified Chainlink feed RWA pools may bind to.
    event RwaFeedApproved(address indexed feed, string description);
    /// @notice v3.3: the team revoked a previously-approved RWA feed (does not affect existing pools).
    event RwaFeedRevoked(address indexed feed);
    /// @notice v3.3 (item 3): the team (timelocked owner) changed a pool's esFERA
    ///         emissions-eligibility flag. Consumed OFF-CHAIN by the emissions pipeline that builds
    ///         each epoch's Merkle leaves (`EmissionsController`/`Distributor` have no on-chain
    ///         notion of per-pool eligibility) — has NO on-chain effect on fee generation/routing.
    event EmissionsEligibilityChanged(bytes32 indexed poolId, bool eligible);
    /// @notice The team (timelocked owner) exempted (or un-exempted) `account` from the depositor
    ///         cooldown check in `withdraw` — see FeraVault.sol's `cooldownExempt` NatSpec for why.
    event CooldownExemptSet(address indexed account, bool exempt);
    /// @notice The team (timelocked owner) activated (or deactivated) automated keeper actions for
    ///         `poolId` — see FeraVault.sol's `keeperActive` NatSpec.
    event KeeperActiveSet(bytes32 indexed poolId, bool active);

    // ── Errors ───────────────────────────────────────────────────────────────────────────
    error ZeroAddress(); // zero-address rejected on keeper setter + immutable ctor wiring
    error DepositsPaused(); // INV-11 (deposits ONLY — withdrawals are never pausable)
    error CooldownActive(); // PARAMS.md#DEPOSIT_COOLDOWN_SEC — depositor's OWN fresh shares
    error TwapGateExceeded(); // PARAMS.md#DEPOSIT_TWAP_GATE_BPS — deposits revert outside the gate
    error GateOutOfBounds(); // setter outside the immutable [50,500]bp legal range (Gamma lesson)
    error MarketClosed();
    error MarketOpen();
    error TwapOutOfBand();
    /// @notice REC-9 fail-closed: the pool's newest TWAP observation is older than TWAP_MAX_STALENESS_SEC
    ///         (a dormant pool) — the deposit gate + rebalance TWAP-sanity legs revert rather than trust a
    ///         stale, near-spot extrapolation. NEVER on the swap path (INV-2). A single swap re-arms it.
    error TwapStale();
    error LaunchpadDisabled();
    error OnlyKeeper();
    error Slippage();
    error UnknownPool();
    error UnknownTranche();
    error ZeroDeposit();
    // ── base+limit+idle strategy errors (contracts/VAULT_STRATEGY_V3.md) ────────────────
    error NotBaseLimitPool(); // action requires a tier-configured tranche (always true post-v3)
    error RebalanceTooSoon(); // min-interval bound (MEME/RWA) — no unbounded rebalance frequency (R-15)
    error NotOutOfRange(); // guarded base recenter needs spot OUTSIDE the base band
    error OorNotPersistent(); // OOR younger than the regime dwell interval (anti-whipsaw)
    error RebalanceSlippage(); // self-swap / venue output below the TWAP-bounded minimum
    error VenueNotAllowed(); // external venue is not on the governance allowlist
    error IdleBpsOutOfBounds(); // idle fraction outside the immutable [0, IDLE_BPS_MAX] legal range
    error BadTier(); // unknown tier id / bad tokenOut selection
    error SingleOutTooLow(); // withdrawSingle could not meet minOut within the slippage bound
    /// @notice v3 NEW: a standalone `selfSwap` call's requested notional exceeds the per-call IL
    ///         budget (MAX_IL_BPS_PER_RECENTER of the tranche's current NAV) — call with a smaller
    ///         `amountIn`, or let `rebalanceBase`'s own internal self-swap size itself (it clamps
    ///         instead of reverting — a PARTIAL recenter, never a revert).
    error IlBudgetExceeded();
    /// @notice v3 NEW: `setVolWidthMultBounds` argument outside the immutable legal range, or
    ///         min > max.
    error WidthMultOutOfBounds();
    /// @notice v3.3 NEW: `createBaseLimitPool`'s designated quote-side token (per `quoteIsToken0`)
    ///         is not on the team-set `allowedQuoteAssets` allowlist. Applies to BOTH regimes.
    error QuoteAssetNotAllowed();
    /// @notice v3.3 NEW: an RWA `createBaseLimitPool` call supplied `oracleFeed == address(0)` or a
    ///         feed not on the team-curated `approvedRwaFeeds` registry. Never applies to MEME.
    error RwaFeedNotApproved();
    /// @notice v3.5 NEW (audit finding, open-kritt): an RWA `createBaseLimitPool` call's
    ///         `sqrtPriceX96` deviates from the approved oracle's price by more than
    ///         `RWA_ORACLE_RECENTER_HYSTERESIS_BPS`. RWA (unlike MEME) has a real, curated price
    ///         reference at creation time — initializing away from it would let the first-depositor
    ///         NAV basis start divorced from the asset's actual value. Never applies to MEME (there
    ///         is no oracle reference to check against for a brand-new memecoin).
    error RwaInitPriceOffOracle();
    /// @notice v3.5 NEW (Finding-1 hardening): an `onlyKeeper` action was attempted on a pool the
    ///         owner has not (yet) activated via `setKeeperActive` — see FeraVault.sol's
    ///         `keeperActive` NatSpec. Never applies to deposits/withdrawals/swaps.
    error PoolNotKeeperActive();
    /// @notice v3.3 FIX (H-1, memo 09): `createBaseLimitPool`'s `key.hooks` is not the Vault's own
    ///         immutable `hook`. With permissionless creation, a pool whose actual v4 hook is
    ///         `address(0)` (static-fee) or an attacker-deployed hook would bypass the real
    ///         FeraHook's callbacks entirely — its manipulation-resistant cumulative-tick TWAP would
    ///         never populate, silently degrading EVERY self-swap bound (§9 fee-routing, `selfSwap`,
    ///         `rebalanceBase`, `withdrawSingle`) to atomically-manipulable spot. The Vault must
    ///         symmetrically require the pool it registers is a real-hook pool (mirrors the hook's
    ///         own `_beforeInitialize` `sender == vault` guard).
    error WrongHook();
    /// @notice v3-hardening (§5.1): an RWA-only action (`rebalanceRwaOracle`/`defendRwaOffHours`) was
    ///         called on a MEME pool.
    error NotRwaPool();
    /// @notice v3-hardening (§5.1): the RWA oracle-anchored recenter could not read a fresh/positive
    ///         Chainlink price (the anchor is mandatory — no blind recenter).
    error OracleUnavailable();
    /// @notice v3-hardening (§5.1): the pool-vs-oracle drift is below `RWA_ORACLE_RECENTER_HYSTERESIS_BPS`
    ///         — there is nothing meaningful to recenter (moving liquidity would be pure churn).
    error OracleDeviationTooSmall();

    /// @notice Deposit into a tranche of `poolId`, ratio-matched across its band set; mints the
    ///         tranche's ERC-20 shares at NAV. Respects pause + TWAP gate (INV-11 — pausable side).
    function deposit(PoolId poolId, uint8 tranche, uint256 amount0, uint256 amount1, uint256 minShares)
        external
        returns (uint256 sharesMinted);

    /// @notice Burn `shares` of a tranche pro-rata across its bands (+ held balances). NEVER
    ///         pausable (INV-11); only the depositor's own 1h cooldown applies.
    function withdraw(PoolId poolId, uint8 tranche, uint256 shares, uint256 minAmount0, uint256 minAmount1)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Timestamp at/after which `account` may `withdraw`/`withdrawSingle` `poolId`/`tranche`
    ///         without hitting `CooldownActive` — see FeraVault.sol's `cooldownExempt` NatSpec
    ///         (including the "RESIDUAL RISK" note for multi-pool callers). Pure view.
    function withdrawReadyAt(PoolId poolId, uint8 tranche, address account) external view returns (uint64);

    /// @notice Checkpoint a tranche: poke its bands, realize fees, skim EXACTLY 10% to the
    ///         RevenueDistributor (INV-3 per tranche, INV-15), retain 90% as pending LP income.
    function collectFees(PoolId poolId, uint8 tranche)
        external
        returns (uint256 fee0, uint256 fee1, uint256 perfFee0, uint256 perfFee1);

    /// @notice Pure split preview — perfFee = 10% of fee, lpFee = remainder. Used by INV-3 tests.
    function previewPerfFee(uint256 fee0, uint256 fee1)
        external
        pure
        returns (uint256 perfFee0, uint256 perfFee1, uint256 lpFee0, uint256 lpFee1);

    // ── BASE + LIMIT + IDLE (contracts/VAULT_STRATEGY_V3.md) — the ONLY strategy ────────────

    /// @notice Register a pool. Builds tranche 0 = Steady + tranche 1 = Active, each a single
    ///         wide vol-adaptive BASE band + a keeper-maintained IDLE reserve; LIMIT bands are
    ///         deployed on demand by `rebalanceLimit`. `quoteIsToken0` (v3.1, §9) fixes which side
    ///         is the liquid quote asset (WETH/USDG-like) for unified fee-routing — immutable
    ///         thereafter. v3.3 (contracts/VAULT_STRATEGY_V3.md §11): PERMISSIONLESS — any address
    ///         may call this now. The caller-gate is replaced by two admin-curated levers: (1) the
    ///         designated quote-side token MUST be on `allowedQuoteAssets` (both regimes) or this
    ///         reverts `QuoteAssetNotAllowed`; (2) for `regime == RWA`, `oracleFeed` MUST be on
    ///         `approvedRwaFeeds` (reverts `RwaFeedNotApproved` otherwise) — MEME needs no such
    ///         check (no oracle dependency). The created pool's `emissionsEligible` flag always
    ///         defaults to FALSE regardless of caller; only the team can opt it in
    ///         (`setEmissionsEligible`).
    function createBaseLimitPool(
        PoolKey calldata key,
        FeraTypes.Regime regime,
        address oracleFeed,
        uint160 sqrtPriceX96,
        bool quoteIsToken0,
        string calldata name_,
        string calldata symbol_
    ) external returns (PoolId poolId);

    /// @notice Set a (pool,tranche)'s tier / idle fraction within the immutable legal bounds.
    ///         onlyOwner (timelocked). v3: the limit skew is NO LONGER a configurable parameter here
    ///         — it is derived deterministically from the tranche's actual token surplus (§3); this
    ///         setter cannot influence it.
    function configureTier(PoolId poolId, uint8 tranche, uint8 tier, uint16 idleBps) external;

    /// @notice Pull the configured IDLE fraction of the base band into the tranche reserve (the
    ///         instant-withdraw + rebalancing buffer). Value-conserving (band→reserve). onlyKeeper.
    function skimIdle(PoolId poolId, uint8 tranche) external;

    /// @notice Record / refresh the base out-of-range (OOR) dwell clock. Permissionless (it can only
    ///         make the guarded base recenter STRICTER — arm a real breach or clear a stale one).
    ///         IDEMPOTENT while OOR persists: only the FIRST out-of-range poke starts the clock;
    ///         repeated pokes while still OOR are a no-op on the timer (audited, contracts/
    ///         VAULT_STRATEGY_V3.md §6 / contracts/THREAT_MODEL.md).
    /// @dev    OPEN_DECISIONS.md#OD-14 FIX: the CLEAR transition (oor=false) only zeroes `oorSince`
    ///         when the recovery is ALSO TWAP-confirmed — a same-block spot flicker cannot forge a
    ///         clear and forfeit real accrued dwell time. The ARM transition stays spot-only by
    ///         design (see FeraVault.pokeOutOfRange's NatSpec).
    function pokeOutOfRange(PoolId poolId, uint8 tranche) external returns (bool outOfRange);

    /// @notice LIMIT-FIRST rebalance: collect the (largely filled) limit band(s) into reserve and
    ///         redeploy ONE limit near spot whose width is VOL-ADAPTIVE (§2) and whose SKEW is
    ///         DETERMINISTICALLY derived from the tranche's actual token surplus, mean-reversion-
    ///         biased toward the Chainlink oracle for RWA pools (§3) — swap-free. Bounded by the
    ///         regime min-interval + TWAP sanity. KEEPER-ONLY (v3.4): every safety property is ALSO
    ///         enforced on-chain (they now guard keeper mistakes/key compromise). Only pokeOutOfRange
    ///         stays permissionless — see contracts/THREAT_MODEL.md + the v3.4 addendum in
    ///         contracts/VAULT_STRATEGY_V3.md.
    function rebalanceLimit(PoolId poolId, uint8 tranche) external;

    /// @notice GUARDED wide-BASE recenter: permitted only on sustained OOR (≥ regime dwell), ≥ the
    ///         regime min-interval since the last rebalance, TWAP-sanity, a hard SWAP-SLIPPAGE bound
    ///         (`MAX_REBALANCE_SLIPPAGE_BPS`, execution quality vs TWAP), AND (v3 NEW) a SEPARATE
    ///         IMPERMANENT-LOSS cap (`MAX_IL_BPS_PER_RECENTER`, absolute NAV-fraction at risk in one
    ///         call): if the self-swap that would balance the recentered base exceeds that NAV
    ///         budget, the call executes a PARTIAL recenter (bounded swap, `BaseRecenterPartial`
    ///         event) instead of reverting — the base band is still fully re-anchored; the leftover
    ///         imbalance is picked up by a later action. KEEPER-ONLY for BOTH modes (v3.4) — see the
    ///         v3.4 addendum in contracts/VAULT_STRATEGY_V3.md.
    function rebalanceBase(PoolId poolId, uint8 tranche, bool selfSwap) external;

    /// @notice Standalone bounded self-swap against the OWN v4 pool (ratio balancing). Spends only
    ///         the tranche's own reserve. Bounded by BOTH the execution-slippage-vs-TWAP check and
    ///         (v3 NEW) the SAME per-call IL-budget notional cap `rebalanceBase` uses (reverts
    ///         `IlBudgetExceeded` rather than silently truncating a user-specified `amountIn` — the
    ///         caller picks a smaller amount instead). KEEPER-ONLY (v3.4, swap path).
    function selfSwap(PoolId poolId, uint8 tranche, bool zeroForOne, uint256 amountIn)
        external
        returns (uint256 amountOut);

    /// @notice Route a bounded ratio-balancing swap through a whitelisted EXTERNAL venue. Executed
    ///         output re-verified ≥ (1 − MAX_REBALANCE_SLIPPAGE_BPS) × pool-TWAP-implied.
    ///         KEEPER-ONLY (v3.4, swap path); the venue allowlist is the second safety boundary.
    function rebalanceViaVenue(PoolId poolId, uint8 tranche, address venue, bool zeroForOne, uint256 amountIn)
        external
        returns (uint256 amountOut);

    /// @notice v3-hardening (§5.1): RWA IN-HOURS oracle-anchored base recenter. KEEPER-ONLY (v3.4); RWA
    ///         only. Re-anchors the base band TOWARD the Chainlink oracle when the pool has drifted
    ///         past `RWA_ORACLE_RECENTER_HYSTERESIS_BPS` during market hours (TWAP-sanity-checked).
    ///         Swap-free / value-conserving. Reverts NotRwaPool / MarketClosed / OracleUnavailable /
    ///         OracleDeviationTooSmall / TwapOutOfBand / RebalanceTooSoon per its gates.
    function rebalanceRwaOracle(PoolId poolId, uint8 tranche) external;

    /// @notice v3-hardening (§5.1): RWA OFF-HOURS / EVENT-WINDOW defense — WIDEN the base band and
    ///         PARTIAL-WITHDRAW a fraction into idle reserve to survive weekend drift + a Monday gap.
    ///         KEEPER-ONLY (v3.4); RWA only; eligible when the market is closed OR an event window is
    ///         flagged. Swap-free / value-conserving. Reverts NotRwaPool / MarketOpen / RebalanceTooSoon.
    function defendRwaOffHours(PoolId poolId, uint8 tranche) external;

    /// @notice Governance allowlist toggle for an external rebalance venue. onlyOwner (timelocked) —
    ///         a trust/governance decision, unlike the mechanical rebalance actions above.
    function setVenueAllowed(address venue, bool allowed) external;

    /// @notice v3.3: team-set allowlist toggle for a QUOTE-side asset `createBaseLimitPool` may
    ///         pair a pool against (both regimes). onlyOwner (timelocked).
    function setAllowedQuoteAsset(address token, bool allowed) external;

    /// @notice v3.3: team-curated RWA oracle-feed registry — approve `feed` (with an off-chain-
    ///         verified `description`) so RWA `createBaseLimitPool` calls may bind to it. onlyOwner
    ///         (timelocked).
    function approveRwaFeed(address feed, string calldata description) external;

    /// @notice v3.3: remove `feed` from the approved RWA registry (does not affect existing pools
    ///         already bound to it). onlyOwner (timelocked).
    function revokeRwaFeed(address feed) external;

    /// @notice v3.3 (item 3): team-only per-pool esFERA emissions-eligibility toggle. Defaults FALSE
    ///         for every pool. Gates ONLY off-chain emissions attribution — NEVER fee generation/
    ///         collection/routing (see the event's NatSpec). onlyOwner (timelocked).
    function setEmissionsEligible(PoolId poolId, bool eligible) external;

    /// @notice Exempt (or un-exempt) `account` from the depositor cooldown check in `withdraw`.
    ///         onlyOwner (timelocked). See `cooldownExempt`'s NatSpec in FeraVault.sol for exactly
    ///         what this does and does not bypass.
    function setCooldownExempt(address account, bool exempt) external;

    /// @notice v3.5 NEW (Finding-1 hardening): activate (or deactivate) automated keeper actions for
    ///         `poolId`. Defaults FALSE for every pool. Gates ONLY `onlyKeeper` rebalance/skim
    ///         actions — NEVER deposits, withdrawals, or swaps. onlyOwner (timelocked). See
    ///         `keeperActive`'s NatSpec in FeraVault.sol.
    function setKeeperActive(PoolId poolId, bool active) external;

    /// @notice v3.5 hardening addendum (audit finding, medium): batched `setKeeperActive` — same
    ///         onlyOwner/UnknownPool semantics, applied to every id in `poolIds`, so a whole
    ///         redeploy's/permissionless-creation wave's worth of pools can be activated (or
    ///         deactivated) in one tx instead of one per pool. Reverts the whole batch on the first
    ///         unknown id. Still emits one `KeeperActiveSet` per pool.
    function setKeeperActiveBatch(PoolId[] calldata poolIds, bool active) external;

    /// @notice v3 NEW: timelocked-owner setter for the vol-adaptive width-multiplier clamp band,
    ///         bounded WITHIN the immutable [VOL_WIDTH_MULT_MIN_LEGAL_BPS,
    ///         VOL_WIDTH_MULT_MAX_LEGAL_BPS] legal range (the Gamma lesson).
    function setVolWidthMultBounds(uint256 minBps, uint256 maxBps) external;

    /// @notice Redeem `shares` of a tranche into ONE token (`tokenOut`), swapping the other leg
    ///         internally against the own pool within the slippage bound; reverts if `minOut` unmet.
    ///         NEVER returns more than the pro-rata NAV. The always-available IN-KIND fallback is the
    ///         plain `withdraw` (never pausable, no swap, no venue) — so redemptions are unblockable
    ///         (INV-11) even if every swap venue is down. NEVER pausable.
    function withdrawSingle(PoolId poolId, uint8 tranche, uint256 shares, address tokenOut, uint256 minOut)
        external
        returns (uint256 amountOut);

    // ── Views ────────────────────────────────────────────────────────────────────────────
    /// @notice The per-(pool, tranche) ERC-20 share token address.
    function shareToken(PoolId poolId, uint8 tranche) external view returns (address);

    /// @notice The regime bound to `poolId`.
    function regimeOf(PoolId poolId) external view returns (FeraTypes.Regime);

    /// @notice Whether `poolId`'s underlying market is currently OPEN, per the same fail-static
    ///         holiday → keeper-flag → on-chain schedule logic the hook's RWA fee overlay reads.
    ///         MEME pools read `true` while their keeper flag is up. Read-only mirror of the
    ///         internal gate — F-12 (Backend marketHours keepers).
    function isMarketOpen(PoolId poolId) external view returns (bool open);

    /// @notice Whether a keeper-flagged scheduled-event session (D-M11) is active on `poolId`.
    function isEventWindow(PoolId poolId) external view returns (bool active);

    /// @notice Whether deposits are paused for `poolId`.
    function depositsPaused(PoolId poolId) external view returns (bool);

    /// @notice Number of tranches on `poolId` (always 2: Steady, Active — D-16).
    function trancheCount(PoolId poolId) external view returns (uint8);

    /// @notice Number of live bands in a tranche (≤ MAX_BANDS_PER_TRANCHE).
    function bandCount(PoolId poolId, uint8 tranche) external view returns (uint256);

    /// @notice Band descriptor (ticks, liquidity, principal-vs-fee class — D-17).
    function bandAt(PoolId poolId, uint8 tranche, uint256 index)
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, bool isPrincipal);

    /// @notice Full band descriptor incl. the base/limit role (isPrincipal ⇒ BASE; isLimit ⇒ the
    ///         inventory-skewed LIMIT; neither ⇒ unused in v3).
    function bandInfo(PoolId poolId, uint8 tranche, uint256 index)
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, bool isPrincipal, bool isLimit);

    /// @notice Retained (90%) fee income awaiting the next checkpoint/withdraw, per tranche.
    function pendingFees(PoolId poolId, uint8 tranche) external view returns (uint256 pending0, uint256 pending1);

    /// @notice The base+limit+idle tier config of a (pool,tranche): (tier, base/limit half-widths in
    ///         ticks — the TIER MAGNITUDE fed to the vol-adaptive multiplier, not necessarily the
    ///         final on-chain width — idle fraction, whether tier-configured).
    function tierOf(PoolId poolId, uint8 tranche)
        external
        view
        returns (uint8 tier, int24 baseHalfTicks, int24 limitHalfTicks, uint16 idleBps, bool set);

    /// @notice First-timestamp the base band went out of range (0 = in range) — the dwell clock.
    function outOfRangeSince(PoolId poolId, uint8 tranche) external view returns (uint64);

    /// @notice The IDLE reserve balances (uninvested buffer) of a (pool,tranche).
    function idleReserves(PoolId poolId, uint8 tranche) external view returns (uint256 reserve0, uint256 reserve1);

    /// @notice Whether `venue` is a governance-whitelisted external rebalance venue.
    function isVenueAllowed(address venue) external view returns (bool);

    /// @notice v3: the current governance-set vol-width-multiplier clamp band (bps of 1x).
    function volWidthMultBounds() external view returns (uint256 minBps, uint256 maxBps);

    /// @notice v3.1 unified fee-routing (§9): whether `poolId`'s token0 is the liquid QUOTE asset
    ///         (the complementary token is the pool's NATIVE/project token). Set once at
    ///         `createBaseLimitPool`, immutable thereafter.
    function quoteIsToken0(PoolId poolId) external view returns (bool);

    /// @notice v3.3: whether `token` is on the team-set quote-asset allowlist (both regimes).
    function allowedQuoteAssets(address token) external view returns (bool);

    /// @notice v3.3: whether `feed` is on the team-curated approved RWA oracle-feed registry.
    function approvedRwaFeeds(address feed) external view returns (bool);

    /// @notice v3.3 (item 3): whether `poolId` is currently opted into esFERA emissions attribution
    ///         by the team. Defaults FALSE. Has NO effect on fee generation/collection/routing.
    function emissionsEligible(PoolId poolId) external view returns (bool);

    /// @notice v3.5 (Finding-1 hardening): whether the automated keeper may act on `poolId` at all.
    ///         Defaults FALSE for every pool. See `keeperActive`'s NatSpec in FeraVault.sol.
    function keeperActive(PoolId poolId) external view returns (bool);

    /// @notice v3.5 hardening addendum (audit finding, medium: silent un-activated pools). Given a
    ///         candidate list of pool ids (e.g. reconstructed off-chain from FeraHook's
    ///         `PoolRegistered` events), returns exactly the subset that is NOT `keeperActive` — a
    ///         one-call diff instead of polling `keeperActive(id)` per pool.
    function inactiveKeeperPools(PoolId[] calldata poolIds) external view returns (PoolId[] memory inactive);
}
