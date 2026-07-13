// Pipeline parameters — reconciled against docs/mechanism/PARAMS.md v2 (97 keys) and
// MASTER_SPEC v0.6 §7/§9. The SHAPE of these constants is frozen by MASTER_SPEC; the VALUES
// below carry their PARAMS.md key in a comment. Changing any value (or any algorithm source)
// bumps the scriptVersionHash embedded in every reproducibility bundle.

// Emission split per epoch — FROZEN (MASTER_SPEC §7, Decision-A″ 2026-07-12): 85 / 5 / 10.
// F-10: revised from the 80/10/10 working prior (Decision-A′ / D-M7). Trader 5% (halved from 10)
// ~doubles wash safety at zero routing cost; the +5 goes to LPs (the TVL bottleneck / direct-LP
// fee gap); treasury kept at 10% as a war-chest. Matches contracts EMISSION_SPLIT_* v2.
// PARAMS.md#EMISSION_SPLIT_LP_BPS / #EMISSION_SPLIT_TRADER_BPS / #EMISSION_SPLIT_TREASURY_BPS
export const SPLIT_LP_BPS = 8500n; // LPs, pro-rata to fees EARNED (vault share holders, INV-14)
export const SPLIT_TRADER_BPS = 500n; // traders, pro-rata to fees PAID
export const SPLIT_TREASURY_BPS = 1000n; // treasury (funded directly; not in the Merkle tree)
export const BPS = 10_000n;

// Emission bound β — timelocked [0,9000] hard cap on the setter (MASTER_SPEC §7).
// PARAMS.md#EMISSION_BETA
export const BETA_BPS = 8000n;

// esFERA instant-exit haircut — timelocked 50% (MASTER_SPEC §7). Used only by the wash-farm
// guardrail (rebate value after immediate exit). PARAMS.md#ES_HAIRCUT_BPS
export const INSTANT_EXIT_KEEP_BPS = 5000n;

// ---------------------------------------------------------------------------
// FERA TWAP hardening — PT-8 FROZEN (PARAMS.md §E). Consumed by pipeline/twap.ts.
// ---------------------------------------------------------------------------
export const FERA_TWAP_WINDOW_SEC = 604_800; // 7 d — PARAMS.md#FERA_TWAP_WINDOW_SEC
export const FERA_TWAP_CLAMP_BPS_PER_OBS = 200; // ±2%/obs — PARAMS.md#FERA_TWAP_CLAMP_BPS_PER_OBS
export const FERA_TWAP_EPOCH_MAX_DROP_BPS = 3000; // 30% — PARAMS.md#FERA_TWAP_EPOCH_MAX_DROP_BPS
export const FERA_TWAP_MIN_CARDINALITY = 5000; // obs/window — PARAMS.md#FERA_TWAP_MIN_CARDINALITY

// ---------------------------------------------------------------------------
// Pool quality score (per-pool caps) — MECHANISM_SPEC §4.4, computed off-chain here (DM-1).
// ---------------------------------------------------------------------------
export const POOL_DIVERSITY_D0 = 50n; // unique CLUSTER-collapsed traders for full divMult (PT-9)
export const POOL_DIVERSITY_MIN_BPS = 2000n; // divMult floor — PARAMS.md#POOL_DIVERSITY_MIN

// ---------------------------------------------------------------------------
// Self-match exclusion (INV-13, MECHANISM_SPEC §4.7) — pipeline-versioned keys.
// ---------------------------------------------------------------------------
export const SELF_MATCH_EXCLUSION = true; // PARAMS.md#SELF_MATCH_EXCLUSION (on)
export const SELF_MATCH_FUND_DEPTH = 2; // PARAMS.md#SELF_MATCH_FUND_DEPTH (first-funder depth)
export const SELF_MATCH_MIN_CLUSTER_SHARE_BPS = 500n; // PARAMS.md#SELF_MATCH_MIN_CLUSTER_SHARE_BPS
// Stance: DEFAULT-ALLOW (PARAMS.md#SELF_MATCH_STANCE) — flow whose trader is a router/solver/
// settlement contract cannot be clustered and counts as external. See pipeline/README.md.

// Reference logistic cap parameters (only used when a snapshot does not carry an on-chain
// capFeraWei). The AUTHORITATIVE cap is EmissionsController's on-chain integer implementation
// (INV-7). This helper must match it bit-for-bit before mainnet.
// PARAMS.md#EMISSION_BUCKET / #CAP_LOGISTIC_K / #CAP_LOGISTIC_TMID_SEC / #CAP_HORIZON_SEC
export const EMITTABLE_SUPPLY_FERA_WEI = 900_000_000n * 10n ** 18n; // 90% of 1B
export const CAP_HORIZON_EPOCHS = 208n; // ~4 years weekly
export const CAP_LOGISTIC_K_E6 = 42_308n; // k = 2.2/yr = 0.0423/wk, E6 fixed point
export const CAP_LOGISTIC_MIDPOINT_EPOCH = 99n; // t_mid = 1.9 yr ≈ week 99

// Version hash inputs — bumping any of the above (or the algorithm) changes the script version
// hash embedded in every reproducibility bundle. NEVER hotfix a posted epoch (MASTER_SPEC §9).
// v2: D-M8 normative ordering + funding-cluster self-match exclusion + PT-8 TWAP.
// v3 (F-10): emission split 80/10/10 → 85/5/10 (Decision-A″). This changes leaf amounts and the
// posted root, so the algo version is bumped; posted-epoch bundles keep their old hash forever.
export const PIPELINE_ALGO_VERSION = "fera-emissions-pipeline/3";
