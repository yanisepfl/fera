// Consensus-critical emissions pipeline — type contract (MASTER_SPEC v0.6 §9, D-M8).
//
// All token amounts are bigint (raw wei / native decimals). All USD values are bigint E6
// (micro-dollars). FERA amounts are bigint wei (18 dec). NO floating point anywhere on a path
// that produces a Merkle leaf.

import type { TokenMeta, PriceE6 } from "../src/lib/prices";

export type Hex = `0x${string}`;
export type Address = Hex;

// kind ∈ {0 trader, 1 lp}  (MASTER_SPEC §9 Merkle leaf; matches Distributor.Claimed kind).
export const KIND_TRADER = 0 as const;
export const KIND_LP = 1 as const;
export type Kind = typeof KIND_TRADER | typeof KIND_LP;

// ---------------------------------------------------------------------------
// Frozen event inputs (subset of §6 relevant to §9), with block/time context the
// indexer records. These are exactly what the reproducibility bundle snapshots.
// F-8 batch: Deposit/Withdraw/FeesCollected/SharePriceCheckpoint carry `uint8 tranche`
// (D-12 — per-pool-per-tranche ERC-20 shares; attribution is per (pool, tranche)).
// ---------------------------------------------------------------------------

export interface SwapEventInput {
  poolId: Hex;
  trader: Address;
  amount0: bigint;
  amount1: bigint;
  lpFeePips: number;
  feeAmount: bigint; // LP fee in the INPUT token (raw)
  zeroForOne: boolean;
  regime: number;
  blockNumber: bigint;
  timestamp: number; // unix seconds
  logIndex: number;
}

export interface DepositEventInput {
  poolId: Hex;
  tranche: number; // F-8 (D-12). 0 = Core (single-tranche pools always 0).
  user: Address;
  amount0: bigint;
  amount1: bigint;
  sharesMinted: bigint;
  blockNumber: bigint;
  timestamp: number;
  logIndex: number;
}

export interface WithdrawEventInput {
  poolId: Hex;
  tranche: number; // F-8 (D-12)
  user: Address;
  amount0: bigint;
  amount1: bigint;
  sharesBurned: bigint;
  blockNumber: bigint;
  timestamp: number;
  logIndex: number;
}

export interface FeesCollectedEventInput {
  poolId: Hex;
  tranche: number; // F-8 (D-12) — a band's fees accrue solely to its owning tranche (INV-15)
  fee0: bigint;
  fee1: bigint;
  perfFee0: bigint;
  perfFee1: bigint;
  blockNumber: bigint;
  timestamp: number;
  logIndex: number;
}

export interface SharePriceCheckpointInput {
  poolId: Hex;
  tranche: number; // F-8 (D-12)
  sharePriceX96: bigint;
  epochId: bigint;
  blockNumber: bigint;
  timestamp: number;
  logIndex: number;
}

// Vault share ERC-20 Transfer (per pool per tranche). Used (a) as cluster edges for the
// funding-cluster self-match exclusion (MECHANISM_SPEC §4.7), and (b) to move share balances
// in the LP fee attribution stream (shares are transferable ERC-20s — INV-14 pays holders).
export interface ShareTransferInput {
  poolId: Hex;
  tranche: number;
  from: Address;
  to: Address;
  shares: bigint;
  blockNumber: bigint;
  timestamp: number;
  logIndex: number;
}

// First-funder edge: `child`'s FIRST inbound funding transfer came from `funder`.
// One edge per child wallet (the first funder, since genesis). The pipeline derives the
// depth-2 expansion (child ↔ funder ↔ funder-of-funder) — see pipeline/cluster.ts.
export interface FundingEdgeInput {
  child: Address;
  funder: Address;
}

// ---------------------------------------------------------------------------
// Non-event inputs to the snapshot: pinned prices, TWAP, quality/caps, boost.
// ---------------------------------------------------------------------------

// token0/token1 for each pool + decimals + the pinned USD price used for THIS epoch's
// valuation. Pinned = read once at snapshot build, never live during the pipeline run.
export interface PoolPricing {
  poolId: Hex;
  token0: TokenMeta;
  token1: TokenMeta;
  price0E6: PriceE6; // token0 USD price (E6), pinned for the epoch
  price1E6: PriceE6;
}

export interface EpochSnapshot {
  epochId: bigint;
  // inclusive block range the snapshot covers
  fromBlock: bigint;
  toBlock: bigint;
  // epoch close timestamp (unix seconds). Share-seconds accrue up to this instant so a holder
  // who never moves after their last event is still credited to epoch end. When absent, the
  // last stream event bounds accrual (documented fallback for legacy snapshots).
  epochEndTs?: number;
  // frozen events
  swaps: SwapEventInput[];
  deposits: DepositEventInput[];
  withdraws: WithdrawEventInput[];
  feesCollected: FeesCollectedEventInput[];
  checkpoints: SharePriceCheckpointInput[];
  // vault share ERC-20 transfers (cluster edges + balance moves). Since genesis for the
  // cluster graph; the attribution stream only uses in-range [fromBlock, toBlock] entries.
  shareTransfers?: ShareTransferInput[];
  // first-funder graph (since genesis) — funding-cluster input (MECHANISM_SPEC §4.7).
  fundingEdges?: FundingEdgeInput[];
  // router / solver / settlement contracts that can never be clustered (default-allow stance,
  // PARAMS.md#SELF_MATCH_STANCE). Their swaps count as external flow. Pinned in the snapshot.
  unclusterableAddresses?: Address[];
  // pinned pricing per pool
  pools: PoolPricing[];
  // FERA/USD TWAP over the PT-8-hardened window (E6): 7d geometric TWAP, ±200bp/obs clamp,
  // 30% epoch drop-clamp vs prevFeraTwapE6, ≥5000-obs cardinality else fail-static to
  // prevFeraTwapE6. Computed by pipeline/twap.ts at snapshot build and PINNED here.
  feraTwapE6: PriceE6;
  // previous epoch's valuation TWAP (E6) — the drop-clamp floor + fail-static fallback.
  prevFeraTwapE6?: PriceE6;
  // logistic cap(epochId) in FERA wei. Sourced from EmissionsController on-chain (authoritative,
  // enforces INV-7) OR the reference logisticCap() helper. See emissions.ts.
  capFeraWei: bigint;
  // OPTIONAL per-pool quality-score override in bps [0..10000]. When absent for a pool, the
  // pipeline derives divMult from CLUSTER-COLLAPSED unique traders (PT-9, MECHANISM_SPEC §4.4):
  //   divMult_p = clamp(uniqueClusters_p / POOL_DIVERSITY_D0, POOL_DIVERSITY_MIN, 1).
  qualityScoreBps?: Record<Hex, number>;
  // OPTIONAL extra per-pool absolute cap (FERA wei), min()-ed into the D-M8 per-pool lock.
  // The normative locks (capShare_p, β·R_p/twap) always apply; this can only lower E_p.
  poolCapFeraWei?: Record<Hex, bigint>;
  // per-account boost multiplier in 1e18 fixed point (1e18 = 1x). FLAT-MODEL / no chain source:
  // the on-chain staking boost was REMOVED (AnchorStaking exposes no boost getter — staking is a
  // flat stake/unstake model), so this is not read from any contract getter. In production it is
  // empty {} ⇒ every account defaults to 1x ⇒ §9 emission attribution is flat/time-weighted, no
  // boost multiplier. Retained (applied to the LP leaf only, normalized WITHIN each pool — D-M8)
  // solely so the emissions leaf math + its counterfactual dry-run tests stay expressible; a
  // non-empty map is a TEST-ONLY override. Safe to delete wholesale in a follow-up.
  boostX18: Record<Address, bigint>;
  // opening vault-share balances per (pool, tranche) at epoch start (carried from prior epoch's
  // closing indexer state). Needed so LP fees that accrue before any in-epoch Deposit are
  // attributed to pre-existing holders. Omit for a fresh pool (all balances start at 0).
  openingShares?: {
    poolId: Hex;
    tranche?: number; // default 0
    balances: { account: Address; shares: bigint }[];
  }[];
}

// ---------------------------------------------------------------------------
// Cluster / self-match exclusion outputs (produced BY the pipeline from the snapshot —
// deterministic, reproducible, published in the bundle). MECHANISM_SPEC §4.7, INV-13.
// ---------------------------------------------------------------------------

// NOTE ON THE NAME: this began life as an inert "boost exclusion" hook (premium-only).
// MASTER_SPEC v0.6 §9 froze the STRONGER semantics — "caught ⇒ zero emissions on that flow":
// the excluded weight is removed from the leaf weight ENTIRELY (base + boost), per
// MECHANISM_SPEC §4.5 ("lpWeight is the share-time-weighted, SELF-MATCH-EXCLUDED fees-earned
// weight") and §4.7 fix #2. The historical field name is kept for interface continuity.
export interface BoostExclusionE6 {
  poolId: Hex;
  // LP leaf: portion of the account's fees-earned weight (E6) attributable to same-cluster
  // swap flow — excluded from the LP leaf weight (zero emissions on that flow).
  lp: { account: Address; weightE6: bigint }[];
  // Trader leaf: fees-paid weight (E6) zeroed because the trader's cluster holds
  // ≥ SELF_MATCH_MIN_CLUSTER_SHARE_BPS of the pool's vault shares (time-weighted).
  trader: { account: Address; weightE6: bigint }[];
}

export interface ClusterInfo {
  rep: Address; // canonical representative = lexicographically smallest member
  members: Address[]; // sorted ascending; only clusters with ≥2 members are reported
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

export interface LeafEntry {
  account: Address;
  kind: Kind;
  amount: bigint; // esFERA wei (18 dec)
  leaf: Hex; // keccak256(abi.encode(epochId, account, kind, amount))
}

export interface PoolBreakdown {
  poolId: Hex;
  regime: number | null;
  feesPaidE6: bigint; // sum of swap fees paid, valued E6
  feesEarnedE6: bigint; // net LP fees earned, valued E6
  revenueE6: bigint; // perf-fee revenue, valued E6
  divMultBps: number; // diversity multiplier actually applied (override or cluster-derived)
  // D-M8 double lock (MECHANISM_SPEC §4.4): E_p = min(capShare_p, β·R_p/twap [, override])
  capShareFeraWei: bigint; // capEpoch · Q_p / ΣQ
  revenueLockFeraWei: bigint; // β · R_p / feraTwap — FINAL, holds after boost by construction
  poolEmissionFeraWei: bigint; // E_p
  // within-pool 85/5/10 split of E_p (Decision-A″, F-10)
  traderEmissionFeraWei: bigint; // s_TR·E_p actually allocated to trader leaves
  lpEmissionFeraWei: bigint; // s_LP·E_p actually allocated to LP leaves
  treasuryFeraWei: bigint; // s_G·E_p + split dust + zero-weight residue
  // self-match exclusion diagnostics
  excludedLpWeightE6: bigint;
  excludedTraderWeightE6: bigint;
}

export interface EpochResult {
  epochId: bigint;
  // headline numbers (mirror EpochFinalized §6)
  capFeraWei: bigint;
  // F-11: revenue valued in FERA wei BEFORE the β bound (= revenueBoundFeraWei · BPS / BETA_BPS).
  // The root-poster passes this to EmissionsController.finalizeEpoch(revenueValuedInFera, ...) so
  // the controller recomputes the same INV-7 envelope on-chain.
  revenueValuedInFeraWei: bigint;
  revenueBoundFeraWei: bigint; // β × revenueValuedInFera
  // D-M8 step 1: the fixed epoch envelope = min(cap, β×rev). Never exceeded.
  epochTotalFeraWei: bigint;
  // Σ_p E_p — what is actually emitted (≤ epochTotal; the per-pool revenue locks and cap
  // shares are FINAL, so a pool bound below its cap share leaves FERA UN-emitted in the
  // bucket — it is never redistributed to other pools; MECHANISM_SPEC §4.4).
  emittedFeraWei: bigint;
  feraTwapE6: PriceE6;
  // split totals (Σ over pools of the within-pool legs)
  traderPoolFeraWei: bigint;
  lpPoolFeraWei: bigint;
  treasuryFeraWei: bigint; // funded directly, NOT in the Merkle tree
  // aggregates
  revenueValueE6: bigint;
  totalFeesPaidE6: bigint;
  totalFeesEarnedE6: bigint;
  // merkle
  leaves: LeafEntry[]; // trader + lp leaves only (kinds 0/1), amount > 0
  merkleRoot: Hex;
  totalEsFeraWei: bigint; // sum of leaf amounts == amount funded to Distributor
  // detail
  pools: PoolBreakdown[];
  // funding-cluster self-match exclusion — computed from the snapshot, published in the bundle
  clusters: ClusterInfo[];
  boostExclusionE6: BoostExclusionE6[];
  // guardrail diagnostics (non-consensus; monitoring only)
  washFarmFlags: { account: Address; feesPaidE6: bigint; rebateValueE6: bigint }[];
}
