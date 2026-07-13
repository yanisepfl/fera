// The Indexer → API data contract (MASTER_SPEC v0.6 §8, conventions v0.2), as concrete
// TypeScript.
//
// These interfaces ARE the Backend↔Frontend contract (D-2: REST/JSON; §8 shapes are the
// contract). Field names here are frozen against §8; changing one is a §12 interface change.
//
// §8 CONVENTIONS v0.2 (pinned 2026-07-11) as applied here:
//   fees            -> pips, integer (3000 = 0.30%); safe as a JS number
//   APR/APY         -> DECIMAL FRACTION rendered as a string ("0.1200" = 12%) — never percent
//   USD values      -> pre-scaled human units, decimal string (e.g. "1234.5600"); strings are
//                      a documented safe superset of the "may be numbers" allowance
//   timestamps      -> unix seconds, JS number
//   token0/token1   -> {address, symbol, decimals} objects
//   FERA/esFERA/raw token amounts -> JSON strings of the RAW 18-dec integer (wei), e.g.
//                      "2500000000000000000000" — this includes amount, projectedEsFera,
//                      emissionsPending, vested, claimable, shares, sFera (resolves OD-5)
//
// "Every number the Frontend shows MUST be reproducible from on-chain data" (§8): each derived
// field documents its formula inline; APR fields link to the formula in api/derive.ts.

export type Address = `0x${string}`;
export type Hex = `0x${string}`;

// token embed shape (§8 conventions v0.2)
export interface TokenInfo {
  address: Address;
  symbol: string | null;
  decimals: number;
}

// Per-tranche view (F-8/D-12 — ADDITIVE on /pools and /pools/:poolId).
export interface TrancheInfo {
  tranche: number; // 0 Core, 1 Anchor
  totalShares: string; // raw share wei (string per conventions)
  tvlUsd: string;
  sharePriceX96: string; // raw X96 integer string
  feeApr: string; // decimal fraction — tranche fees vs tranche TVL, derive.feeApr()
}

// GET /pools
export interface PoolListItem {
  poolId: Hex;
  regime: number; // 0 MEME 1 RWA
  token0: TokenInfo; // §8 conventions v0.2 object shape
  token1: TokenInfo;
  currentFeePips: number; // LIVE dynamic fee (read-through cached, TTL ≤ ~1s) w/ indexed fallback
  currentFeeSource: "live" | "indexed"; // provenance of currentFeePips
  feeApr: string; // decimal fraction ("0.1200" = 12%) — see derive.feeApr()
  emissionsApr: string; // decimal fraction — see derive.emissionsApr()
  tvlUsd: string; // reserves valued at pinned prices
  depthVsBest: string; // ratio of FERA ±1% depth to best competing vanilla pool (1.0 == parity)
  tranches: TrancheInfo[]; // F-8 additive: per-tranche supply/TVL/share-price/APY
}

// GET /pools/:poolId
export interface FeeHistoryPoint {
  timestamp: number;
  feePips: number;
}
export interface StrategyLogEntry {
  timestamp: number;
  kind: number; // 0 initialMint 1 recenter 2 widen 3 partialWithdraw 4 compoundInPlace 5 dripDeploy 6 bandConsolidate (F-8)
  tickLower: number;
  tickUpper: number;
  oraclePrice: string;
  justificationHash: Hex;
  txHash: Hex;
}
export interface PoolDetail extends PoolListItem {
  positionBand: { tickLower: number | null; tickUpper: number | null };
  marketHoursState: "open" | "closed" | null; // null for MEME (no market hours)
  oraclePrice: string; // last StrategyAction oraclePrice (raw), "0" if none
  poolPrice: string; // last observed pool price from sqrtPrice checkpoint (X96), "0" if none
  tvlUsd: string;
  cumFeesUsd: string;
  cumRevenueUsd: string;
  // F-8 JitPenaltyApplied (D-14): cumulative fees forfeited by early removers and donated to
  // in-range LPs — it is LP YIELD (additive pool metric).
  jitFeesForfeitedToLpsUsd: string;
  feeHistory: FeeHistoryPoint[];
  strategyLog: StrategyLogEntry[];
}

// GET /pools/:poolId/depth
export interface CompetitorDepth {
  competitorPoolId: Hex;
  dex: string; // "univ3" | "univ4"
  feePips: number;
  depth1PctUsd: string; // ±1% depth in USD
}
export interface PoolDepthResponse {
  poolId: Hex;
  pairKey: string;
  feraDepth1PctUsd: string;
  competitors: CompetitorDepth[];
  best: CompetitorDepth | null; // deepest competitor
  depthVsBest: string; // feraDepth / bestCompetitorDepth
}

// GET /positions/:account — one item PER (pool, tranche) position (F-8/D-12 additive field).
export interface PositionItem {
  poolId: Hex;
  tranche: number; // F-8 additive: which share class this position holds (0 Core, 1 Anchor)
  shares: string; // raw share wei string
  valueUsd: string;
  feesEarned: string; // trailing fees earned attributed to this holder (USD)
  emissionsPending: string; // esFERA wei string, accrued this (not-yet-posted) epoch — see derive
}

// GET /epochs/current
export interface EpochCurrent {
  epochId: string;
  endsAt: number; // unix seconds
  feesPaid: string; // caller-agnostic total fees paid this epoch (USD) OR per-account if ?account=
  feesEarned: string;
  projectedEsFera: string; // projected esFERA emissions for the epoch so far (FERA wei)
}

// GET /epochs/:id/proof/:account
export interface ProofEntry {
  kind: number; // 0 traderRebate 1 lpReward
  amount: string; // esFERA wei
  proof: Hex[];
}
export interface ProofResponse {
  epochId: string;
  account: Address;
  root: Hex | null;
  // An account may hold BOTH a trader-rebate (kind 0) and an lp-reward (kind 1) leaf, so this is
  // a list. §8 shows the singular `{ kind, amount, proof[] }`; returning all matching leaves is a
  // documented superset (see OPEN_DECISIONS D-BK-3). Filter with ?kind=0|1.
  claims: ProofEntry[];
}

// GET /staking/:account
export interface StakingResponse {
  account: Address;
  sFera: string; // raw FERA wei string
  boost: string; // boostX18 rendered as a multiplier string (e.g. "1.5")
  multiplierPoints: string; // raw wei string
  revenueShareApr: string; // decimal fraction — annualized revenue-share vs staked value
}

// GET /vesting/:account — F-3 / §8 (added v0.2, OD-6/FE-6). One entry per VestStarted grant.
// amount/vested/claimable are esFERA/FERA WEI strings (18-dec raw integers, conventions v0.2);
// startTs/endTs unix seconds.
export interface VestingGrant {
  grantId: string; // deterministic: `${blockNumber}:${logIndex}` of the VestStarted event
  amount: string; // total esFERA granted (wei string)
  startTs: number;
  endTs: number;
  vested: string; // amount × clamp(now − startTs, 0, endTs − startTs) / (endTs − startTs)
  claimable: string; // vested (VestClaimed is now indexed account-level; per-grant claimed is still
                     // an approximation as the event carries no grantId — D-BK-9 / BK-1)
}

// GET /transparency/emissions
export interface EmissionsSeriesPoint {
  epochId: string;
  cap: string;
  revenueBound: string;
  emitted: string;
  feraTwap: string;
}
export interface EmissionsTransparency {
  series: EmissionsSeriesPoint[];
}

// GET /transparency/revenue
export interface RevenueByToken {
  token: Address;
  toStakers: string;
  toTreasury: string;
  toOps: string;
  received: string;
}
export interface RevenueTransparency {
  toStakers: string;
  toTreasury: string;
  toOps: string;
  byToken: RevenueByToken[];
}
