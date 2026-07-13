"""
FERA pressure-test structural parameters.

SINGLE SOURCE for the constants used by every harness in this directory.

!!! DEPENDENCY FLAG (Pressure-Test / Agent 8) !!!
    docs/mechanism/PARAMS.md DOES NOT EXIST as of 2026-07-10.
    Every value below is a STRUCTURAL DEFAULT read out of:
        - docs/SHARED_CONTEXT.md  (locked design intent)
        - docs/MASTER_SPEC.md     (accounting constants, §7)
    When Mechanism (Agent 1) freezes PARAMS.md, replace the values tagged
    `SPEC_FREEZE` and re-run every harness. Any verdict below is PRELIMINARY
    until PARAMS.md exists. See OPEN_DECISIONS.md item PT-1.

All fee rates are handled internally as fractions (0.003 == 0.30%).
On-chain the hook expresses fees in "pips" = hundredths of a bip:
    3000 pips = 0.30% ; 30000 pips = 3.00% ; 100 pips = 1bp.
"""

# ---------------------------------------------------------------------------
# Accounting constants — MASTER_SPEC §7 (frozen shape, values as stated there)
# ---------------------------------------------------------------------------
PERF_FEE            = 0.10    # 10% of collected LP fees. IMMUTABLE (MASTER_SPEC §7).
BETA                = 0.80    # emission bound: emitted <= beta * revenue. timelocked.
TRADER_SPLIT        = 0.45    # 45% of epoch emission -> traders, pro-rata fees PAID.
LP_SPLIT            = 0.45    # 45% -> LPs, pro-rata fees EARNED.
TREASURY_SPLIT      = 0.10    # 10% -> treasury.
INSTANT_EXIT_HAIRCUT= 0.50    # esFERA instant-exit haircut (keep 50%).
MAX_BOOST           = 2.00    # up to ~2x boost on a staker's OWN emissions.
REV_SPLIT           = (0.50, 0.25, 0.25)  # stakers / treasury / ops. IMMUTABLE.
VEST_MONTHS         = 6       # esFERA linear vest to FERA 1:1.
EPOCH_WEEKS         = 1

# ---------------------------------------------------------------------------
# MEME regime fee curve  — SPEC_FREEZE (structural range only; PARAMS.md pending)
#   SHARED_CONTEXT: "fee in [~0.3%, ~3-5%]; asymmetric sell-side fee under
#   one-sided net flow; EWMA realized-vol estimator from tick movement."
# ---------------------------------------------------------------------------
MEME_FEE_FLOOR      = 0.0030  # 0.30%   (30 bps)   SPEC_FREEZE
MEME_FEE_CEIL       = 0.0400  # 4.00%   (400 bps)  SPEC_FREEZE  (mid of 3-5%)
MEME_VOL_TO_FEE_K   = 0.60    # fee = floor + k * EWMA(|ret|)-scaled. SPEC_FREEZE
MEME_VOL_REF        = 0.010   # per-step |ret| that maps the fee to mid-range. SPEC_FREEZE
MEME_EWMA_LAMBDA    = 0.94    # RiskMetrics-style EWMA decay on per-step returns.
MEME_SELL_SURCHARGE = 0.50    # +50% multiplicative surcharge on the fee for the
                              # heavy side under strongly one-sided net flow. SPEC_FREEZE

# ---------------------------------------------------------------------------
# RWA regime fee curve — SPEC_FREEZE
#   SHARED_CONTEXT: "low fee ~1-5bps in market hours; widened ~30-100bps when
#   closed; overlay scaling with |pool price - Chainlink feed|, clamped."
# ---------------------------------------------------------------------------
RWA_FEE_HOURS       = 0.0003  # 3 bps in-hours base.   SPEC_FREEZE
RWA_FEE_CLOSED      = 0.0060  # 60 bps off-hours base. SPEC_FREEZE
RWA_FEE_FLOOR       = 0.0001  # 1 bp   SPEC_FREEZE
RWA_FEE_CEIL        = 0.0100  # 100 bps SPEC_FREEZE
RWA_DEV_OVERLAY_K   = 0.50    # overlay = k * |pool-oracle|/oracle, added to base. SPEC_FREEZE
RWA_HYSTERESIS      = 0.0050  # 50 bps oracle move to trigger recenter. SPEC_FREEZE
RWA_BAND_HALFWIDTH  = 0.0050  # +/-50 bps tick band around oracle (tight). SPEC_FREEZE
RWA_TWAP_SANITY     = 0.0100  # pool TWAP must be within 100 bps of oracle. SPEC_FREEZE

# ---------------------------------------------------------------------------
# Vanilla baselines for the V4 superiority test.
# ---------------------------------------------------------------------------
VANILLA_LOW         = 0.0030  # 30 bps  (Uniswap 0.30% tier)
VANILLA_HIGH        = 0.0100  # 100 bps (Uniswap 1.00% tier)

# Net-of-perf-fee hurdle the regime fee must clear to match a vanilla pool that
# charges the SAME nominal rate on the SAME volume:
#     regime_rate * (1 - PERF_FEE) > vanilla_rate
#     => regime_rate > vanilla_rate / (1 - PERF_FEE)
PERF_HURDLE_MULT    = 1.0 / (1.0 - PERF_FEE)   # 1.1111...

# ---------------------------------------------------------------------------
# FERA TWAP / emission valuation
# ---------------------------------------------------------------------------
FERA_TWAP_WINDOW_MIN = 60     # manipulation-capped TWAP window (minutes). SPEC_FREEZE
