// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title FeraConstants
/// @notice Frozen-shape accounting constants (MASTER_SPEC §7) + Mechanism-frozen v2 params
///         (docs/mechanism/PARAMS.md, 97 keys). Values LOCKED by the spec are hardcoded; values
///         Mechanism has NOT yet frozen are placeholders tagged `TODO(spec-freeze): PARAMS.md#<key>`
///         and MUST NOT be treated as final.
/// @dev    Everything here is a compile-time constant so it is auditably immutable and free.
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

    /// @notice Genesis mint to Treasury: 10% of max supply — immutable (§7).
    uint256 internal constant GENESIS_TREASURY_BPS = 1_000; // 10%

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

    /// @notice Max boost ~2x on a staker's own LP emissions ONLY (Decision B / INV-13). Timelocked.
    uint256 internal constant MAX_BOOST_WAD = 2e18;

    /// @notice Epoch length 1 week. Timelocked (§7).
    uint256 internal constant EPOCH_LENGTH = 7 days;

    // ─────────────────────────────────────────────────────────────────────────────────────
    // MEME regime fee curve — PARAMS.md §A (v2 freeze).
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
    ///         manipulation-sensitive strategy consumers — the deposit gate and the recenter TWAP-sanity
    ///         legs (REC-9 / convergence N4/N5). On a DORMANT pool (no swaps for longer than this) the
    ///         newest observation is old and `consultTwapTick` would extrapolate `_lastTick` across an
    ///         unbounded gap, yielding a near-spot average with false confidence. Those consumers
    ///         FAIL-CLOSED (revert `TwapStale`) instead of trusting it. This bounds ONLY the
    ///         strategy/deposit-gate paths — it NEVER touches swaps (INV-2: swaps never revert; the swap
    ///         path does not read this oracle). Spot can only move via a swap, and every swap refreshes
    ///         the oracle, so a live pool is never stale; only a genuinely inactive pool trips it, and a
    ///         single swap (permissionless) re-arms deposits. Must exceed the widest TWAP window (1800s)
    ///         with headroom so normal quiet periods do not block deposits.
    /// @dev    TODO(spec-freeze): PARAMS.md#TWAP_MAX_STALENESS_SEC — [PROVISIONAL] pending the same
    ///         Mechanism sim (M4/DM-4) that freezes TWAP_OBS_*. The MECHANISM (fail-closed) is final.
    uint32 internal constant TWAP_MAX_STALENESS_SEC = 7_200; // [PROVISIONAL] 2h ≫ 1800s window
    /// PARAMS.md#DEPOSIT_TWAP_GATE_BPS (FROZEN v2). Default gate; timelocked WITHIN the immutable
    /// legal range below — the bounds live in code (the Gamma lesson: no config path may widen them).
    uint256 internal constant DEPOSIT_TWAP_GATE_DEFAULT_BPS = 200; // ±2%
    uint256 internal constant DEPOSIT_TWAP_GATE_MIN_BPS = 50; // immutable legal floor
    uint256 internal constant DEPOSIT_TWAP_GATE_MAX_BPS = 500; // immutable legal ceiling
    // PARAMS.md#DEPOSIT_RATIO_MATCHED = true (immutable — structural: pro-rata band mints).

    // ─────────────────────────────────────────────────────────────────────────────────────
    // MEME vault strategy — band ladder + drip + guarded recenter — PARAMS.md §D (v2 FROZEN).
    // Ladder 30/40/30 at k=1.3 / 2.0 / full-range. k frozen as k, converted to ticks here:
    //   k=1.3 → log_1.0001(1.3) ≈ 2624 ticks; k=2.0 → ≈ 6932 ticks; ±10% → ≈ 953 ticks.
    // ─────────────────────────────────────────────────────────────────────────────────────

    uint256 internal constant MEME_LADDER_CORE_WEIGHT_BPS = 3_000; // PARAMS.md#MEME_LADDER_CORE_WEIGHT_BPS
    uint256 internal constant MEME_LADDER_MID_WEIGHT_BPS = 4_000; // PARAMS.md#MEME_LADDER_MID_WEIGHT_BPS
    uint256 internal constant MEME_LADDER_TAIL_WEIGHT_BPS = 3_000; // PARAMS.md#MEME_LADDER_TAIL_WEIGHT_BPS
    int24 internal constant MEME_LADDER_CORE_TICKS = 2_624; // k=1.3 (PARAMS.md#MEME_LADDER_CORE_K)
    int24 internal constant MEME_LADDER_MID_TICKS = 6_932; // k=2.0 (PARAMS.md#MEME_LADDER_MID_K)

    /// PARAMS.md#MEME_TRANCHE_COUNT (FROZEN v2, D-16): MEME ships single-tranche (Core only).
    uint8 internal constant MEME_TRANCHE_COUNT = 1;
    uint8 internal constant RWA_TRANCHE_COUNT = 2; // Core + Anchor (D-16)
    uint8 internal constant MAX_TRANCHES = 2;

    /// PARAMS.md#MEME_DRIP_MIN_INTERVAL_SEC (FROZEN v2). Daily drip cadence.
    uint32 internal constant MEME_DRIP_MIN_INTERVAL_SEC = 86_400;
    /// PARAMS.md#MEME_DRIP_MIN_SIZE_BPS (FROZEN v2). Skip dust drips (< 0.10% of tranche TVL).
    uint256 internal constant MEME_DRIP_MIN_SIZE_BPS = 10;
    /// PARAMS.md#MEME_DRIP_BAND_K (FROZEN v2): k=1.3 single-sided limit band (no swap — Charm).
    int24 internal constant MEME_DRIP_BAND_TICKS = 2_624;
    /// PARAMS.md#MEME_DRIP_CONSOLIDATE_BPS (FROZEN v2, D-17): compound into an existing FEE band
    /// whose center is within ±10% of spot instead of minting a new band. ±10% ≈ 953 ticks.
    int24 internal constant MEME_DRIP_CONSOLIDATE_TICKS = 953;
    /// PARAMS.md#MEME_MAX_BANDS_PER_TRANCHE (FROZEN v2, immutable hard cap, D-17).
    uint256 internal constant MEME_MAX_BANDS_PER_TRANCHE = 8;

    // Guarded principal recenter (D-15 / INV-5″ — the ONLY principal-touching MEME action):
    /// PARAMS.md#MEME_RECENTER_DEPTH_FLOOR_MULT_BPS (FROZEN v2): 1.0× v1-full-range equivalent.
    uint256 internal constant MEME_RECENTER_DEPTH_FLOOR_MULT_BPS = 10_000;
    /// PARAMS.md#MEME_RECENTER_PERSIST_SEC (FROZEN v2): breach must persist ≥ 24h.
    uint32 internal constant MEME_RECENTER_PERSIST_SEC = 86_400;
    /// PARAMS.md#MEME_MIN_RECENTER_INTERVAL_SEC (FROZEN v2): ≥ 7d between recenters.
    uint32 internal constant MEME_MIN_RECENTER_INTERVAL_SEC = 604_800;
    /// PARAMS.md#MEME_RECENTER_TWAP_WINDOW_SEC / #MEME_RECENTER_TWAP_SANITY_BPS (FROZEN v2).
    uint32 internal constant MEME_RECENTER_TWAP_WINDOW_SEC = 1_800;
    uint256 internal constant MEME_RECENTER_TWAP_SANITY_BPS = 500; // ±5%
    /// PARAMS.md#MEME_RECENTER_MAX_SLIPPAGE_BPS (FROZEN v2): value-conservation bound on execution.
    uint256 internal constant MEME_RECENTER_MAX_SLIPPAGE_BPS = 100; // 1%
    // PARAMS.md#MEME_RECENTER_RANDOM_WINDOW_SEC = 300 — keeper-side timing discipline (off-chain).

    // ─────────────────────────────────────────────────────────────────────────────────────
    // RWA vault strategy — PARAMS.md §C (v2 additions frozen).
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// PARAMS.md#RWA_RECENTER_HYSTERESIS_BPS (FROZEN). Oracle move required to recenter (H < w).
    uint256 internal constant RWA_HYSTERESIS_BPS = 50; // 0.50%
    /// PARAMS.md#RWA_TWAP_SANITY_BPS (FROZEN). Max |pool-TWAP − oracle| to allow recenter (INV-6).
    uint256 internal constant RWA_TWAP_SANITY_BPS = 200; // 2.00%
    /// PARAMS.md#RWA_TWAP_WINDOW_SEC (FROZEN). Pool-TWAP sanity window.
    uint32 internal constant RWA_TWAP_WINDOW = 1_800; // 30 min
    /// PARAMS.md#RWA_MIN_RECENTER_INTERVAL_SEC (**v2 FROZEN — PT-6 ENFORCED**): bounds
    /// tick-boundary griefing to ≤0.48%/day worst case. Timelocked legal range [3600,86400].
    uint32 internal constant RWA_MIN_RECENTER_INTERVAL_SEC = 14_400; // 4h
    /// PARAMS.md#RWA_OFFHOURS_WITHDRAW_FRAC (**v2 FROZEN — PT-7**): q=0.60 off-hours de-risk cap.
    uint256 internal constant RWA_OFFHOURS_WITHDRAW_FRAC_BPS = 6_000;
    /// PARAMS.md#RWA_EVENT_WITHDRAW_FRAC (**v2 FROZEN — D-M11**): q=0.80 on keeper-flagged
    /// scheduled-event sessions only (bounded, fail-static: flag absent ⇒ normal q).
    uint256 internal constant RWA_EVENT_WITHDRAW_FRAC_BPS = 8_000;
    /// TODO(spec-freeze): PARAMS.md#RWA_BAND_HALFWIDTH_BPS = 100 — [PROVISIONAL] (DM-6 / V4).
    /// 1 tick ≈ 1bp; scaffold converts bps→ticks 1:1 (exact conversion at wire time).
    int24 internal constant RWA_BAND_HALF_WIDTH_TICKS = 100; // PROVISIONAL (±1.0%)
    /// TODO(spec-freeze): PARAMS.md#RWA_ANCHOR_BAND_HALFWIDTH_BPS = 500 — [PROVISIONAL].
    int24 internal constant RWA_ANCHOR_BAND_HALF_WIDTH_TICKS = 500; // PROVISIONAL (±5%)
    /// TODO(spec-freeze): PARAMS.md#RWA_STALE_AFTER_OPEN_SEC — [PROVISIONAL] per-feed (D-9).
    uint256 internal constant ORACLE_STALENESS_MAX = 3_600; // PROVISIONAL (1h)

    // ─────────────────────────────────────────────────────────────────────────────────────
    // cap(t) logistic (S-curve, ~4-year horizon) — PARAMS.md §E.
    // ─────────────────────────────────────────────────────────────────────────────────────
    /// PARAMS.md#EMISSION_BUCKET (FROZEN) = 90% of fixed 1B. Logistic asymptote L.
    uint256 internal constant CAP_LOGISTIC_L = 900_000_000e18; // 900M
    /// TODO(spec-freeze): PARAMS.md#CAP_LOGISTIC_K / #CAP_LOGISTIC_TMID_SEC / #CAP_HORIZON_SEC —
    ///   EmissionsController.capAt() is a LINEAR ramp placeholder until the logistic is wired.
}
