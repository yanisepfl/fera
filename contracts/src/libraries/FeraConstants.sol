// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title FeraConstants
/// @notice Frozen-shape accounting constants (MASTER_SPEC §7) + Mechanism-frozen v2/v3 params
///         (docs/mechanism/PARAMS.md, 97 keys). Values LOCKED by the spec are hardcoded; values
///         Mechanism has NOT yet frozen are placeholders tagged `TODO(spec-freeze): PARAMS.md#<key>`
///         and MUST NOT be treated as final.
/// @dev    Everything here is a compile-time constant so it is auditably immutable and free.
///
///         V3 NOTE (contracts/VAULT_STRATEGY_V3.md): the legacy Core/Mid/Tail band-ladder + drip +
///         INV-5″ guarded-recenter constants are REMOVED (not deprecated — deleted). Nothing was
///         ever deployed, so there is no backward-compatibility surface; base+limit+idle is now the
///         ONLY vault strategy, for BOTH regimes. Do not re-add MEME_LADDER_*/MEME_DRIP_*/
///         MEME_RECENTER_* — they described a mechanism that no longer exists in `FeraVault.sol`.
///
///         V3-HARDENING NOTE (2026-07-14, this pass — contracts/VAULT_STRATEGY_V3.md §5.1/§12): the
///         RWA regime's oracle-anchored recenter + off-hours WIDEN / partial-withdraw defenses are
///         RESTORED on the base+limit+idle shape (they were vestigial after the v3 unification —
///         OD-4). The `RWA_ORACLE_RECENTER_HYSTERESIS_BPS`/`RWA_OFFHOURS_WIDEN_MULT_BPS`/
///         `RWA_OFFHOURS_WITHDRAW_FRAC_BPS` rows below are the (re-scoped, base+limit-native) heirs of
///         the removed ladder-era `RWA_HYSTERESIS_*`/`RWA_*_WITHDRAW_FRAC_*` — same INTENT (RWA prices
///         mean-revert to the real stock; recenter TOWARD the oracle in-hours, batten down off-hours),
///         new mechanism (re-anchor the base band, not a ladder). MEME's base recenter is made
///         CONSERVATIVE in the same pass (long dwell + long dedicated interval — §5.1): for a
///         memecoin we do NOT chase the pump.
library FeraConstants {
    // ─────────────────────────────────────────────────────────────────────────────────────
    // LOCKED (MASTER_SPEC §7 — immutable rows). These are contractual and safe to hardcode.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// @notice Basis-point denominator (100% = 10_000 bps).
    uint256 internal constant BPS = 10_000;

    /// @notice Performance fee: exactly 10% of *collected LP fees* (INV-3, per tranche INV-15).
    uint256 internal constant PERF_FEE_BPS = 1_000; // 10.00%

    /// @notice RevenueDistributor split 50/25/25 (stakers/treasury/ops) — immutable (INV-10).
    uint256 internal constant REV_STAKERS_BPS = 5_000; // 50%
    uint256 internal constant REV_TREASURY_BPS = 2_500; // 25%
    uint256 internal constant REV_OPS_BPS = 2_500; // 25%

    /// @notice Emission split per epoch **85 / 5 / 10** (LPs / traders / treasury) — **Decision-A″
    ///         FROZEN 2026-07-12** (was 80/10/10; MASTER_SPEC §7 emission-split row / OD F-10).
    ///         Applied OFF-CHAIN in the §9 pipeline (no on-chain consumer); wired here so the repo
    ///         has one source of truth. Sum == BPS (unit-tested). Trader slice halved 10→5 doubles
    ///         wash-safety margin at zero routing cost; the +5 goes to LPs (the TVL bottleneck).
    uint256 internal constant EMIT_LPS_BPS = 8_500; // 85%
    uint256 internal constant EMIT_TRADERS_BPS = 500; // 5%
    uint256 internal constant EMIT_TREASURY_BPS = 1_000; // 10%

    /// @notice esFERA instant-exit forfeiture split 1/3 burn / 1/3 stakers / 1/3 revenue (INV-9).
    /// @dev    PARAMS.md#FORFEIT_BURN_FRAC: the BURN third takes the rounding remainder (F-4).
    uint256 internal constant FORFEIT_PARTS = 3;

    /// @notice FERA fixed supply: 1,000,000,000 * 1e18 — immutable (§7).
    uint256 internal constant FERA_MAX_SUPPLY = 1_000_000_000e18;

    /// @notice Genesis mint: 10% of max supply — immutable (§7). Stage-3 (v3.2,
    ///         `contracts/VAULT_STRATEGY_V3.md` §10): this 10% (100,000,000 FERA) is minted to
    ///         `GenesisVesting.sol`, NOT directly to the treasury EOA — see the two constants below.
    uint256 internal constant GENESIS_TREASURY_BPS = 1_000; // 10%

    /// @notice `GenesisVesting` cliff — 1 year. Nothing is claimable before `start + this`.
    uint256 internal constant GENESIS_VESTING_CLIFF_DURATION = 365 days;

    /// @notice `GenesisVesting` total horizon — 4 years (1yr cliff + 3yr linear release after it).
    ///         Deliberately mirrors `EmissionsController.capAt`'s own `horizon = 4 * 365 days` —
    ///         a tokenomics-consistency choice (both the genesis unlock and the 90% emission cap
    ///         complete on the same 4-year horizon), not a technical dependency between the two.
    uint256 internal constant GENESIS_VESTING_TOTAL_DURATION = 4 * 365 days;

    /// @notice Timelock delay governing all "timelocked" params — immutable 48h (§7, INV-12).
    uint256 internal constant TIMELOCK_DELAY = 48 hours;

    /// @notice v4 dynamic-fee sentinel. Mirrors v4-core LPFeeLibrary.DYNAMIC_FEE_FLAG (unit-tested).
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;

    /// @notice v4 max LP fee (100% in pips). Mirrors LPFeeLibrary.MAX_LP_FEE.
    uint24 internal constant MAX_LP_FEE_PIPS = 1_000_000;

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Hook flag target (MASTER_SPEC §5 v0.5 / D-14) — VERIFIED against v4-core Hooks.sol:
    //   beforeInitialize(1<<13=0x2000) + afterAddLiquidity(1<<10=0x0400)
    //   + afterRemoveLiquidity(1<<8=0x0100) + beforeSwap(1<<7=0x0080) + afterSwap(1<<6=0x0040)
    //   + afterAddLiquidityReturnDelta(1<<1=0x0002) + afterRemoveLiquidityReturnDelta(1<<0=0x0001)
    //   = 0x25C3. The Orchestrator's provisional salt target is CONFIRMED CORRECT.
    //   Deployment (5) mines CREATE2 salt s.t. address & 0x3FFF == 0x25C3 (avoid 0x91-prefix, D-8).
    // ─────────────────────────────────────────────────────────────────────────────────────
    uint160 internal constant HOOK_FLAG_TARGET = 0x25C3;

    // ─────────────────────────────────────────────────────────────────────────────────────
    // TIMELOCKED DEFAULTS (§7 — value is a starting point, mutable behind 48h timelock).
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// @notice Emission bound β default 0.8 → emitted ≤ β × revenue (INV-7). Timelocked, hard cap 0.9.
    uint256 internal constant BETA_DEFAULT_WAD = 0.8e18;

    /// @notice Hard on-chain ceiling on the timelocked β setter — **0.9 (D-M9 C3 / SEC-3 #5)**,
    ///         tightened from the earlier 1.0. Wash-farm break-even inverts at β ≥ 1/0.9 ≈ 1.111
    ///         (Mechanism §4.2); the 0.9 cap keeps a safety margin no timelock action can widen.
    uint256 internal constant BETA_MAX_WAD = 0.9e18;

    /// @notice esFERA linear vest duration ~6 months. Timelocked (§7).
    uint256 internal constant ES_VEST_DURATION = 182 days;

    /// @notice Instant-exit haircut 50%. Timelocked (§7).
    uint256 internal constant INSTANT_EXIT_HAIRCUT_BPS = 5_000; // 50%

    /// @notice sFERA unstake cooldown since the account's LAST stake (v3.4 simple-staking model).
    ///         The single anti reward-JIT guard: revenue streams continuously (accumulator), so a
    ///         moment-staker earns ~nothing, and this makes stake-before-lump/exit-after impossible
    ///         too. Every stake (incl. top-ups) re-arms it on the whole balance. Timelocked (§7).
    ///         NOTE: the former MAX_BOOST_WAD (~2x lock boost) was REMOVED with the boost concept —
    ///         power is flat pro-rata staked FERA; INV-13/PT-2 closed by design (see AnchorStaking).
    uint32 internal constant UNSTAKE_COOLDOWN_SEC = 7 days;

    /// @notice Epoch length 1 week. Timelocked (§7).
    uint256 internal constant EPOCH_LENGTH = 7 days;

    // ─────────────────────────────────────────────────────────────────────────────────────
    // MEME regime fee curve — PARAMS.md §A (v2 freeze). Consumed by FeraHook/FeeLogic; also the
    // SOLE data source (via FeeLogic.sigmaTicks/widthMultiplierBps) for the v3 vol-adaptive band
    // sizing in FeraVault — see §2 below. Do NOT duplicate the estimator; read it.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// PARAMS.md#MEME_FEE_FLOOR_PIPS (**v2 FROZEN: 3000 → 3400**, PT-3: 0.9·34bp > 30bp so regime
    /// LPs strictly beat vanilla-30 net of the 10% perf fee even in dead-calm sessions).
    uint24 internal constant MEME_FEE_FLOOR_PIPS = 3_400; // 0.34%
    /// PARAMS.md#MEME_FEE_CEIL_PIPS (FROZEN). Normal ceiling (reached at σ≈139 ticks RMS).
    uint24 internal constant MEME_FEE_CEIL_PIPS = 30_000; // 3.00%
    /// PARAMS.md#MEME_FEE_HARD_MAX_PIPS (FROZEN). Absolute cap incl. sell-side adder.
    uint24 internal constant MEME_FEE_HARD_MAX_PIPS = 50_000; // 5.00%

    /// @notice Vol→fee mapping (MECHANISM_SPEC §1.5): feeBase = clamp(FLOOR + SLOPE·max(0,σ−SIGMA0)).
    /// TODO(spec-freeze): PARAMS.md#MEME_FEE_SLOPE_PIPS_PER_TICK = 200 — [PROVISIONAL] (DM-6, V3
    ///   realized-tick histogram). NON-ZERO so the mechanism responds to vol; conservative launch value.
    uint256 internal constant MEME_FEE_SLOPE_PIPS_PER_TICK = 200;
    /// TODO(spec-freeze): PARAMS.md#MEME_FEE_SIGMA0_TICKS = 4 — [PROVISIONAL] dead-band (micro-noise
    ///   stays at floor).
    uint256 internal constant MEME_FEE_SIGMA0_TICKS = 4;
    /// PARAMS.md#MEME_SELL_ADDER_K_PIPS (FROZEN, timelocked [0,20000]). Max sell-side adder at
    /// imbalance = −1 (fully one-sided dump); MECHANISM_SPEC §1.6. ADDITIVE pips scaled by flow imb.
    uint256 internal constant MEME_SELL_ADDER_K_PIPS = 20_000; // 2.00%

    /// @notice EWMA realized-vol estimator decays, Q16 fixed-point (λ_fp = round(λ·65536)).
    /// MECHANISM_SPEC §1.2 / storage layout §1.3. Asymmetric attack/release ratchet.
    /// TODO(spec-freeze): PARAMS.md#MEME_VOL_LAMBDA_UP/_DOWN, #MEME_FLOW_LAMBDA — [PROVISIONAL]
    ///   (DM-6, gated on V3 swap-frequency). NON-ZERO conservative launch values.
    uint256 internal constant MEME_VOL_LAMBDA_UP = 45_875; // 0.70·2^16 — fast attack (~2-swap half-life)
    uint256 internal constant MEME_VOL_LAMBDA_DOWN = 64_225; // 0.98·2^16 — slow release (~34-swap half-life)
    uint256 internal constant MEME_FLOW_LAMBDA = 58_982; // 0.90·2^16 — signed-flow EWMA decay
    /// PARAMS.md#MEME_ONE (immutable). Fixed-point unit for the Q16 λ.
    uint256 internal constant MEME_ONE = 65_536; // 2^16
    /// PARAMS.md#MEME_VOL_CLAMP (immutable). Overflow guard on volEwmaX (σ_max ≈ 131072 ticks ≫ ceil).
    uint256 internal constant MEME_VOL_CLAMP = 1 << 50;

    // ─────────────────────────────────────────────────────────────────────────────────────
    // RWA regime fee curve — PARAMS.md §B.
    // ─────────────────────────────────────────────────────────────────────────────────────

    uint24 internal constant RWA_FEE_INHOURS_PIPS = 200; // PARAMS.md#RWA_FEE_OPEN_BASE_PIPS (2bp)
    uint24 internal constant RWA_FEE_OFFHOURS_PIPS = 3_000; // PARAMS.md#RWA_FEE_CLOSED_BASE_PIPS
    uint24 internal constant RWA_FEE_CEIL_PIPS = 10_000; // PARAMS.md#RWA_FEE_CEIL_PIPS (100bp)
    uint24 internal constant RWA_ORACLE_FAIL_FEE_PIPS = 30_000; // PARAMS.md#RWA_ORACLE_FAIL_FEE_PIPS
    /// PARAMS.md#RWA_DEV_SLOPE (FROZEN, timelocked). +20 pips of fee per 1 bp of |pool−oracle|/oracle
    /// deviation (⇒ +20 bp fee per 1% deviation). MECHANISM_SPEC §2.3.
    uint256 internal constant RWA_DEV_SLOPE_PIPS_PER_BP = 20;
    /// PARAMS.md#RWA_STALE_AFTER_OPEN_SEC — [PROVISIONAL] ≈2× feed heartbeat (confirm per feed, D-9).
    /// In-hours staleness beyond this ⇒ oracle-fail (blind fee); off-hours staleness is EXPECTED and
    /// is NOT a failure (the last in-hours print is the weekend-drift reference). MECHANISM_SPEC §2.2.
    uint256 internal constant RWA_STALE_AFTER_OPEN_SEC = 3_600; // TODO(chain-confirm): per-feed heartbeat

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Anti-JIT fee-forfeiture guard — PARAMS.md §D2 (D-14, v2 FROZEN). INV-1″.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// PARAMS.md#JIT_PENALTY_WINDOW_SEC_MEME (FROZEN v2). Timelocked legal range [300,7200].
    uint32 internal constant JIT_PENALTY_WINDOW_MEME = 1_800; // 30 min
    /// PARAMS.md#JIT_PENALTY_WINDOW_SEC_RWA (FROZEN v2). Timelocked legal range [60,3600].
    uint32 internal constant JIT_PENALTY_WINDOW_RWA = 600; // 10 min
    // PARAMS.md#JIT_PENALTY_DECAY = linear over window (immutable — encoded in FeraHook math).
    // PARAMS.md#JIT_DONATION_FALLBACK = skip if no in-range recipient (immutable — encoded in hook).

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Deposit hardening — PARAMS.md §D2 (OD-V5 / Gamma vector, v2 FROZEN).
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// PARAMS.md#DEPOSIT_COOLDOWN_SEC (FROZEN v2). Veda-style lock on the depositor's OWN shares.
    uint32 internal constant DEPOSIT_COOLDOWN_SEC = 3_600; // 1h
    /// PARAMS.md#DEPOSIT_TWAP_WINDOW_SEC (FROZEN v2). NAV-mint reference TWAP window.
    uint32 internal constant DEPOSIT_TWAP_WINDOW_SEC = 600; // 10 min

    /// @notice Minimum wall-clock spacing between TWAP ring CHECKPOINTS (R-23). The hook keeps a
    ///         floating "head" observation advanced on every swap (so same-block manipulation is still
    ///         excluded) but only freezes a new ring slot once per this interval. With TWAP_OBS_CARD
    ///         slots that gives an effective anchor depth of ~(CARD−1)·SPACING of REAL time, so the
    ///         averaging window can actually reach the configured 600/1800s even on ~100ms-block
    ///         chains — the collapse R-23 flagged. Must satisfy (CARD−1)·SPACING ≥ max TWAP window
    ///         (currently 1800s): (24−1)·90 = 2070 ≥ 1800. ✓
    /// @dev    TODO(spec-freeze): PARAMS.md#TWAP_OBS_SPACING_SEC / #TWAP_OBS_CARDINALITY —
    ///         [PROVISIONAL] pending Mechanism sim (M4/DM-4) on the target chain's block time and the
    ///         ≥10× manipulation-cost bar. The MECHANISM (spacing-gated ring) is implemented; only the
    ///         two magnitudes below are provisional.
    uint32 internal constant TWAP_OBS_SPACING_SEC = 90; // [PROVISIONAL]
    uint16 internal constant TWAP_OBS_CARDINALITY = 24; // [PROVISIONAL] (CARD−1)·SPACING = 2070s ≥ 1800s

    /// @notice Max age of the newest TWAP observation before a reading is treated as UNUSABLE by the
    ///         manipulation-sensitive strategy consumers — the deposit gate and the rebalance TWAP-
    ///         sanity legs (REC-9 / convergence N4/N5). On a DORMANT pool (no swaps for longer than
    ///         this) the newest observation is old and `consultTwapTick` would extrapolate `_lastTick`
    ///         across an unbounded gap, yielding a near-spot average with false confidence. Those
    ///         consumers FAIL-CLOSED (revert `TwapStale`) instead of trusting it. This bounds ONLY the
    ///         strategy/deposit-gate paths — it NEVER touches swaps (INV-2: swaps never revert; the
    ///         swap path does not read this oracle). Spot can only move via a swap, and every swap
    ///         refreshes the oracle, so a live pool is never stale; only a genuinely inactive pool
    ///         trips it, and a single swap (permissionless) re-arms deposits.
    /// @dev    TODO(spec-freeze): PARAMS.md#TWAP_MAX_STALENESS_SEC — [PROVISIONAL] pending the same
    ///         Mechanism sim (M4/DM-4) that freezes TWAP_OBS_*. The MECHANISM (fail-closed) is final.
    uint32 internal constant TWAP_MAX_STALENESS_SEC = 7_200; // [PROVISIONAL] 2h ≫ 1800s window
    /// PARAMS.md#DEPOSIT_TWAP_GATE_BPS (FROZEN v2). Default gate; timelocked WITHIN the immutable
    /// legal range below — the bounds live in code (the Gamma lesson: no config path may widen them).
    uint256 internal constant DEPOSIT_TWAP_GATE_DEFAULT_BPS = 200; // ±2%
    uint256 internal constant DEPOSIT_TWAP_GATE_MIN_BPS = 50; // immutable legal floor
    uint256 internal constant DEPOSIT_TWAP_GATE_MAX_BPS = 500; // immutable legal ceiling
    // PARAMS.md#DEPOSIT_RATIO_MATCHED = true (immutable — structural: pro-rata band mints).

    /// @notice Hard cap on live bands per tranche (D-17 legacy naming kept for the constant's
    ///         identity in prior audits; v3 semantics: base + limit rarely exceed 2, this is a
    ///         defensive ceiling, not a ladder-sizing knob).
    uint256 internal constant MAX_BANDS_PER_TRANCHE = 8;

    /// @notice RWA Chainlink-feed staleness bound used by the (non-reverting) oracle read that feeds
    ///         the v3 inventory-driven limit skew's mean-reversion bias (§3 below). A stale/absent
    ///         feed degrades to pure inventory-driven skew (never reverts the rebalance).
    uint256 internal constant ORACLE_STALENESS_MAX = 3_600; // PROVISIONAL (1h)

    // ─────────────────────────────────────────────────────────────────────────────────────
    // v3 BASE + LIMIT + IDLE strategy — contracts/VAULT_STRATEGY_V3.md. THE ONLY vault strategy
    // (the legacy Core/Mid/Tail ladder + drip + INV-5″ guarded recenter is REMOVED, not stubbed).
    // The industry-standard shape (Arrakis/Gamma/Charm/Steer): ONE wide symmetric BASE around spot
    // holding most of the capital (its width now VOL-ADAPTIVE, §2), ONE narrow LIMIT near spot whose
    // skew is INVENTORY-DRIVEN (§3, deterministic — never a static config knob), and an explicit
    // IDLE reserve (% of NAV) for instant withdrawals + a rebalancing buffer. Per-tranche TIER config:
    // Steady (wide base / small limit / larger idle) vs Active (narrow base / aggressive limit / small
    // idle) — these are now base MAGNITUDES the vol multiplier scales, not the final width.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// @notice Tier ids passed to `createBaseLimitPool` / stored per (pool,tranche).
    uint8 internal constant TIER_STEADY = 0;
    uint8 internal constant TIER_ACTIVE = 1;

    // Steady tier — wide base, small limit, larger idle (conservative capital). Half-widths below are
    // the TIER BASE MAGNITUDE fed into the vol-adaptive multiplier (§2), not necessarily the final
    // on-chain width.
    int24 internal constant STEADY_BASE_HALF_TICKS = 6_932; // ±100% (k=2.0) wide symmetric base
    int24 internal constant STEADY_LIMIT_HALF_TICKS = 2_624; // ±30% narrow limit
    uint16 internal constant STEADY_IDLE_BPS = 1_000; // 10% of NAV kept idle

    // Active tier — narrow base, aggressive limit, MATERIAL limit budget (yield-max capital).
    int24 internal constant ACTIVE_BASE_HALF_TICKS = 2_624; // ±30% narrow base (8.1x CE)
    int24 internal constant ACTIVE_LIMIT_HALF_TICKS = 953; // ±10% aggressive limit
    /// @dev The skim fraction FUNDS THE LIMIT BAND (skimIdle -> reserve -> rebalanceLimit deploys it),
    ///      so this is the tranche's effective LIMIT BUDGET, not dead capital. 20% per the limit-band
    ///      backtest (docs/research/LIMIT_BAND_BACKTEST.md): heavy limit wins on established/choppy/
    ///      crashing tokens (monotone to the grid edge; +14..+37pp median per regime window), but is a
    ///      4-6x opportunity-cost drag during LAUNCH-PHASE hyper-pumps (real Robinhood Chain pools,
    ///      §4.5) — so NEW price-discovery pools should be configured LIMIT-LIGHT via configureTier
    ///      (LAUNCH preset: 0-500 bps) and flipped to this default once discovery cools. Model optimum
    ///      sat at the 75% grid edge with optimistic fills; 20% is deliberately well inside it.
    ///      Shadow-run on live venue telemetry before the mainnet freeze (§5 of the research note).
    uint16 internal constant ACTIVE_IDLE_BPS = 2_000; // 20% limit budget (was 3% pre-research)

    /// @notice Hard bound on the keeper/owner-settable idle fraction (misuse-resistance: an idle of
    ///         100% would silently un-invest the whole vault). Timelocked-owner set WITHIN this.
    uint16 internal constant IDLE_BPS_MAX = 3_000; // 30%

    /// @notice Limit-skew must stay in (5000, 9500] — always straddles spot (never strictly
    ///         single-sided) so the limit both improves CE AND holds a rebalancing sliver. v3: the
    ///         VALUE within this bound is now DERIVED from the tranche's actual token surplus
    ///         (`FeraVault._inventorySkewBps`), never a static/governed number (§3).
    uint16 internal constant LIMIT_SKEW_MIN_BPS = 5_001;
    uint16 internal constant LIMIT_SKEW_MAX_BPS = 9_500;

    /// @notice v3: RWA mean-reversion oracle bias on the inventory-driven limit skew (§3). The signed
    ///         pool-vs-oracle deviation is clamped to ± this bound before blending into the skew score
    ///         (bounds the influence of an extreme/manipulated oracle read), and its BLEND WEIGHT
    ///         against the pure-inventory score is capped at `ORACLE_BIAS_WEIGHT_BPS` — inventory
    ///         surplus remains the dominant signal; the oracle only nudges within it.
    uint256 internal constant ORACLE_BIAS_MAX_DEV_BPS = 1_000; // ±10% cap on the deviation INPUT
    uint256 internal constant ORACLE_BIAS_WEIGHT_BPS = 3_000; // oracle contributes ≤30% of the score

    /// @notice v3: anti-whipsaw DWELL (how long an out-of-range base must persist before a guarded
    ///         recenter may fire) is DECOUPLED from the min-interval floor between rebalances
    ///         (previously the SAME constant served both, conflating "is this move real" with "how
    ///         often can we act at all").
    ///
    ///         V3-HARDENING (2026-07-14, §5.1): the MEME dwell is RAISED 900→3_600 (15 min → 1h). A
    ///         base recenter realises IL through its self-swap; for a strongly TRENDING memecoin many
    ///         small IL-capped recenters stacking is a real loss (the "aggressive recentering loses
    ///         money" failure our own sim showed). We do NOT chase the pump: a base recenter must now
    ///         wait out a FULL HOUR of sustained, TWAP-confirmed out-of-range — not a transient 15-min
    ///         blip. Everyday rebalancing is carried by the swap-free limit-fill (`rebalanceLimit`),
    ///         which keeps the short general interval below and no dwell. RWA's dwell stays long.
    uint32 internal constant MEME_OOR_DWELL_SEC = 3_600; // 1h — do NOT chase; confirm a genuine move
    uint32 internal constant RWA_OOR_DWELL_SEC = 14_400; // 4h — unchanged, RWA is calm

    /// @notice Min spacing between successive GENERAL rebalance actions (R-15 anti-griefing floor),
    ///         PER REGIME. This governs the swap-free everyday rebalancer (`rebalanceLimit`) plus
    ///         `selfSwap`/`rebalanceViaVenue`. MEME stays SHORT (30 min) so the limit-fill can track a
    ///         volatile pair responsively; the base RECENTER is separately, and much more strictly,
    ///         gated (see MEME_BASE_RECENTER_MIN_INTERVAL_SEC). RWA unchanged (slow cadence suits a
    ///         comparatively stable reference price).
    uint32 internal constant MEME_MIN_REBALANCE_INTERVAL_SEC = 1_800; // 30 min (limit-fill cadence)
    uint32 internal constant RWA_MIN_REBALANCE_INTERVAL_SEC = 14_400; // 4h (unchanged)

    /// @notice V3-HARDENING (2026-07-14, §5.1) — DEDICATED min-interval for the IL-realising BASE
    ///         RECENTER (`rebalanceBase`, and the restored RWA oracle-recenter / off-hours defend),
    ///         tracked on its OWN clock (`lastBaseRecenterTs`) SEPARATE from the general
    ///         `lastRebalanceTs`. Two reasons the base recenter needs its own, much longer, clock:
    ///           1. CONSERVATISM — for MEME we let the volatility-scaled fee compensate IL and rely on
    ///              the wide vol-adaptive band + swap-free limit-fill; the base recenter should fire
    ///              RARELY (≤ ~4×/day at 6h), so a trending/whipsawing path cannot stack many small
    ///              IL-capped recenters into a real loss.
    ///           2. NO CROSS-STARVE (closes OD-13) — if the base recenter shared the general clock, a
    ///              cheap `rebalanceLimit` every 30 min would reset it and the base could NEVER reach
    ///              its 6h gap (permanent starvation). A dedicated clock makes the base recenter
    ///              independent of limit-fill activity while still strictly bounded.
    ///         [PROVISIONAL] — 6h MEME (hours, not minutes); RWA reuses its 4h general interval.
    uint32 internal constant MEME_BASE_RECENTER_MIN_INTERVAL_SEC = 21_600; // 6h — base recenter is RARE

    // ─────────────────────────────────────────────────────────────────────────────────────
    // V3-HARDENING (2026-07-14) — RWA regime-appropriate defenses RESTORED on base+limit+idle
    // (contracts/VAULT_STRATEGY_V3.md §5.1). RWA prices MEAN-REVERT to the underlying real stock, so
    // (a) in-hours we recenter the base band TOWARD the Chainlink oracle when the pool drifts past a
    // hysteresis threshold (TWAP-sanity-checked so a spot spike cannot trigger it) — the OPPOSITE of
    // MEME, where chasing the price loses money; (b) off-hours (market closed) or during a flagged
    // event window (earnings), we WIDEN the base band and PARTIAL-WITHDRAW a fraction into idle
    // reserve so weekend drift + a Monday open gap cannot realise IL into a tight stale-priced band.
    // All swap-free (band<->reserve only ⇒ zero IL by construction), bounded, permissionless-but-
    // on-chain-verified like the rest of the rebalance surface.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// @notice In-hours pool-vs-oracle deviation (bps of the oracle price) beyond which the RWA
    ///         base band may be recentered TOWARD the oracle. Below this the pool is close enough to
    ///         the real price that moving liquidity is pure churn. [PROVISIONAL] 2%.
    uint256 internal constant RWA_ORACLE_RECENTER_HYSTERESIS_BPS = 200; // 2%

    /// @notice Off-hours / event-window WIDEN multiplier (bps of 1x = BPS) applied to the RWA base
    ///         tier half-width when battening down. 2x ⇒ the defensive band is twice as wide, so a
    ///         weekend drift / Monday gap is far less likely to blow clean through it. [PROVISIONAL].
    uint256 internal constant RWA_OFFHOURS_WIDEN_MULT_BPS = 20_000; // 2.0x

    /// @notice Off-hours / event-window fraction of the base (bps of the closed base's own amounts)
    ///         PARTIAL-WITHDRAWN into idle reserve instead of redeployed — a buffer that survives a
    ///         Monday open gap without being adversely filled at a stale weekend price, and is instant-
    ///         withdrawable. Bounded well below half so the pool keeps meaningful depth. [PROVISIONAL].
    uint256 internal constant RWA_OFFHOURS_WITHDRAW_FRAC_BPS = 2_000; // 20%

    /// @notice Pool-TWAP window + spot-vs-TWAP sanity for the rebalance gates (price can snap back;
    ///         a lone spot spike whose TWAP disagrees must NOT trigger a base recenter).
    uint32 internal constant REBALANCE_TWAP_WINDOW_SEC = 1_800; // 30 min
    uint256 internal constant REBALANCE_TWAP_SANITY_BPS = 500; // ±5% spot-vs-TWAP

    /// @notice Hard max-SLIPPAGE bound on ANY rebalancing token-ratio swap — whether executed as a
    ///         self-swap against the vault's OWN v4 pool or routed through a whitelisted external
    ///         venue. Executed output MUST be ≥ (1 − this) × the pool-TWAP-implied output, else the
    ///         action reverts. This bounds EXECUTION QUALITY (price impact vs the TWAP reference) —
    ///         it is a DIFFERENT bound from `MAX_IL_BPS_PER_RECENTER` below (v3 clarification): a
    ///         trade can clear this ratio bound (e.g. execute within 1% of TWAP-implied) and still put
    ///         a large ABSOLUTE fraction of tranche NAV at risk in one shot if the trade itself is
    ///         huge — that absolute-NAV-fraction risk is what the IL cap bounds.
    uint256 internal constant MAX_REBALANCE_SLIPPAGE_BPS = 100; // 1%

    /// @notice v3 NEW — IL-AWARE STAGED RECENTER. Caps the NOTIONAL (value, in token1 terms) that any
    ///         ONE guarded-base-recenter self-swap (or standalone `selfSwap` call) may put at risk, as
    ///         a fraction of the tranche's pre-action NAV. If the "ideal" 50/50-rebalancing amount
    ///         exceeds this budget, `rebalanceBase` swaps ONLY up to the budget (a PARTIAL recenter —
    ///         `StrategyKind.BaseRecenterPartial`) and re-anchors the base band regardless (re-ticking
    ///         alone does not realize IL — only the swap's price impact does); the leftover imbalance
    ///         stays in the tranche's reserve for a LATER action (once the min-interval has re-elapsed)
    ///         to continue via `selfSwap` or the swap-free `rebalanceLimit`. PROVABLY BOUNDED: a swap
    ///         can never lose more value than it puts in (amountOut ≥ 0 always), so capping the
    ///         notional to `ilBudget = NAV × MAX_IL_BPS_PER_RECENTER / BPS` trivially bounds the
    ///         worst-case realized loss of that swap to ≤ `ilBudget` — independent of price-gap size.
    uint256 internal constant MAX_IL_BPS_PER_RECENTER = 300; // 3% of tranche NAV per call [PROVISIONAL]

    // ─────────────────────────────────────────────────────────────────────────────────────
    // v3 — VOL-ADAPTIVE POSITION SIZING (§2), REBALANCED for LVR (v3-hardening 2026-07-14, §5.1).
    //
    // WHY THIS IS THE MEME STRATEGY (Loss-Versus-Rebalancing rationale — Milionis et al. "AMM and
    // Loss-Versus-Rebalancing"; concentrated-liquidity LP studies; Bunni/am-AMM): recentering a
    // TRENDING asset REALIZES the loss — recentering literally *is* the "R" in LVR. For a memecoin
    // (which trends, does not mean-revert) active base recentering is a provably losing move, not
    // merely a cadence to slow down. The correct memecoin strategy is therefore: a WIDE base that
    // stays IN RANGE through big moves and essentially NEVER needs recentering, HELD, with the
    // volatility-scaled dynamic fee acting as the LVR compensation; near-spot depth/capital-
    // efficiency is supplied by the NARROW LIMIT, which is rebalanced by FLOW (swap-free limit-fill),
    // never by forced recenters. So for a HIGH-realized-vol MEME pair the base half-width must
    // APPROACH FULL RANGE — hence the max multiplier below is large (25x default / 50x legal): at
    // high σ, STEADY's 6932-tick magnitude × 25 ≈ 173k ticks (and `_bandAround` clamps to the true
    // usable full range), i.e. a wide-hold, near-v2-style base. A CALM pair still runs tight (0.5x
    // floor) for capital efficiency. RWA is the OPPOSITE philosophy (mean-reverts to the oracle → it
    // is recentered TOWARD the oracle, §5.1) and has no EWMA vol signal — RWA multiplier is fixed 1x.
    //
    // Width multiplier is a linear ramp with a dead-band off the SAME EWMA the MEME fee reads
    // (FeraHook's packed `_memeState` via `IFeraHook.memeStateOf` → `FeeLogic.sigmaTicks` — NEVER
    // re-estimated here), CLAMPED to a governance-set [min,max] band (`FeraVault.volWidthMult*Bps`,
    // timelocked WITHIN the immutable legal range below — the Gamma lesson: bounds live in code), so
    // the width can never degenerate to zero nor blow out unbounded.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// @notice Default governance-set clamp band (bps of 1x = BPS). 0.5x floor / 25x ceiling. The high
    ///         ceiling is deliberate (LVR — a volatile MEME base should approach FULL RANGE so it holds
    ///         through the move and is never recentered; the narrow limit supplies CE). [PROVISIONAL].
    uint256 internal constant VOL_WIDTH_MULT_MIN_BPS_DEFAULT = 5_000; // 0.5x (calm pair runs tight)
    uint256 internal constant VOL_WIDTH_MULT_MAX_BPS_DEFAULT = 250_000; // 25x (volatile pair ≈ full-range)
    /// @notice Immutable LEGAL range the timelocked owner's `setVolWidthMultBounds` can never widen
    ///         past (the Gamma lesson — bounds live in code, not just in a mutable default). The 50x
    ///         legal ceiling keeps `tierHalf(≤6932) × 50 = 346_600 < int24 max`; `_bandAround` further
    ///         clamps the result to the pool's true usable tick range, so it can never overflow.
    uint256 internal constant VOL_WIDTH_MULT_MIN_LEGAL_BPS = 1_000; // 0.1x hard floor
    uint256 internal constant VOL_WIDTH_MULT_MAX_LEGAL_BPS = 500_000; // 50x hard ceiling
    /// @notice Dead-band (ticks of σ) below which the multiplier sits at its floor — mirrors
    ///         `MEME_FEE_SIGMA0_TICKS`'s intuition (micro-noise should not widen the band) but is a
    ///         DISTINCT, independently-tunable constant (sizing and fee-pricing are separate concerns
    ///         that happen to share the same σ input).
    uint256 internal constant VOL_WIDTH_MULT_SIGMA0_TICKS = 4;
    /// @notice Linear ramp slope (bps of multiplier per tick of σ above the dead-band). Steepened
    ///         150→300 (v3-hardening §5.1) so a genuinely volatile MEME pair reaches a very wide,
    ///         hold-in-range base at a realistic σ: raw = 5000 + 300·(σ−4) hits ~4.5x by σ≈137 (the
    ///         regime the MEME fee curve calls "at its ceiling") and the 25x default cap by σ≈820. The
    ///         wider the pair's realized vol, the wider (→ full-range) and more hold-forever its base.
    uint256 internal constant VOL_WIDTH_MULT_SLOPE_BPS_PER_TICK = 300;

    // ─────────────────────────────────────────────────────────────────────────────────────
    // cap(t) logistic (S-curve, ~4-year horizon) — PARAMS.md §E.
    // ─────────────────────────────────────────────────────────────────────────────────────
    /// PARAMS.md#EMISSION_BUCKET (FROZEN) = 90% of fixed 1B. Logistic asymptote L.
    uint256 internal constant CAP_LOGISTIC_L = 900_000_000e18; // 900M
    /// TODO(spec-freeze): PARAMS.md#CAP_LOGISTIC_K / #CAP_LOGISTIC_TMID_SEC / #CAP_HORIZON_SEC —
    ///   EmissionsController.capAt() is a LINEAR ramp placeholder until the logistic is wired.
}
