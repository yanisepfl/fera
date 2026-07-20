/**
 * FERA API data contract - TypeScript mirror of MASTER_SPEC §8
 * (Indexer → API contract, Backend 4 ↔ Frontend 3).
 *
 * RULE (MASTER_SPEC §6/§8): the Frontend reads ONLY these shapes from Backend's API.
 * It NEVER reads the chain directly for list/aggregate views. Field names below are
 * the §8 field names verbatim; where §8 says "incl. X" without naming every field,
 * we model the minimum the UI needs and flag the assumption in frontend/OPEN_DECISIONS.md.
 *
 * Units convention used by the FE (documented, since §8 leaves units to Backend):
 *  - *Pips   : hundredths of a bip (MASTER_SPEC §5). 3400 = 0.34%, 30000 = 3.00%.
 *  - *Apr    : decimal fraction. 0.184 = 18.4% APR.
 *  - *Usd    : USD, already decimal-scaled by Backend from token metadata (may be a JS number).
 *  - amounts named token0/token1 raw counts are decimal-scaled by Backend (§6).
 *  - FERA/esFERA/raw-token amounts are JSON **strings** (18-dec integers) to avoid float
 *     precision loss (§8 Conventions v0.2). Covers `amount`, `projectedEsFera`,
 *     `emissionsPending`, `vested`, `claimable`. Format for display with lib/format.esFera().
 *  - timestamps: unix seconds unless the field name ends in `Ms`.
 */

// ----------------------------------------------------------------------------
// Primitives
// ----------------------------------------------------------------------------

/** v4 PoolId, bytes32 hex. */
export type PoolId = `0x${string}`;
export type Address = `0x${string}`;

/** MASTER_SPEC §5: enum Regime { MEME, RWA } // 0,1. EVENT reserved for v2. */
export type Regime = "MEME" | "RWA";
export const REGIME_BY_ID: Record<number, Regime> = { 0: "MEME", 1: "RWA" };

/**
 * Risk class = the vault's per-pool share class (MASTER_SPEC §4 / VAULT_ARCHITECTURE §2.3,
 * D-12). The on-chain/§6 field is `uint8 tranche` (0 = Core, 1 = Anchor); we NEVER surface
 * the word "tranche" in user copy (D-18, BarnBridge/SEC) - see lib/riskClass.ts for the
 * user-facing labels. RWA pools ship both classes; MEME defaults to Core only (D-16).
 */
export type RiskClass = "CORE" | "ANCHOR";
// 0 = ANCHOR/"Steady" (TIER_STEADY, ±100% wide base), 1 = CORE/"Active" (TIER_ACTIVE, ±30%
// narrow base) — verified against FeraConstants.sol/FeraVault.sol; must mirror
// lib/riskClass.ts#RISK_CLASS_META's `tranche` fields exactly (that file is the source of truth).
export const RISK_CLASS_BY_TRANCHE: Record<number, RiskClass> = { 0: "ANCHOR", 1: "CORE" };

/**
 * Additive §8 field (F-8 batch): each pool exposes up to two share classes, each an ERC-20
 * over a disjoint band set with its own NAV/fee/emissions attribution (INV-15). Optional so
 * older payloads without it still parse; MEME pools carry a single Core entry (D-16).
 */
export interface TrancheInfo {
  /** §6 uint8 tranche id: 0 = Core, 1 = Anchor. */
  tranche: number;
  riskClass: RiskClass;
  /** ERC-20 share symbol for this class, e.g. "fACT-NVDA" (Active) / "fSTD-NVDA" (Steady). */
  shareSymbol?: string;
  /** trailing LP fee yield for this class, net of the 10% perf fee (decimal APR). */
  feeApr: number;
  /** esFERA emissions APR for this class (decimal). */
  emissionsApr: number;
  tvlUsd: number;
}

/**
 * Token metadata. §8 lists `token0`/`token1`; §6 says Backend applies decimals from
 * token metadata. We assume the API embeds symbol+decimals so the UI can render a
 * pair without a second lookup. (See OPEN_DECISIONS OD-1.)
 */
export interface Token {
  address: Address;
  symbol: string;
  decimals: number;
}

/** RWA underlying-market state. Drives the RWA fee widen and band widen (§ SHARED_CONTEXT 2). */
export type MarketHoursState = "OPEN" | "CLOSED" | "HOLIDAY" | "PRE" | "POST";

// ----------------------------------------------------------------------------
// Live market facts (pre-launch live mode)
// ----------------------------------------------------------------------------

/**
 * REAL market stats for the pool's UNDERLYING venue, fetched live by the backend
 * (GeckoTerminal / Robinhood Chain). Served pre-deployment alongside `vaultLive:false`:
 * market numbers are real; vault numbers don't exist yet. `tvlUsd` here is the venue
 * pool's reserve — NOT vault TVL (that's `PoolSummary.tvlUsd`, inactive pre-launch).
 */
export interface PoolMarketStats {
  /** base-token price, USD */
  priceUsd: number;
  /** 24h price change, decimal fraction (-0.221 = -22.1%) */
  priceChange24h: number;
  volume24hUsd: number;
  /** the underlying pool's TVL (reserve in USD) */
  tvlUsd: number;
  /** buys + sells over 24h */
  txns24h: number;
  /** venue id, e.g. "uniswap-v3-robinhood" */
  dex: string;
  /** humanized venue, e.g. "Uniswap v3" */
  dexLabel: string;
  poolAddress: string;
  source: "geckoterminal";
  /** unix seconds the snapshot was fetched upstream (~60s cache) */
  fetchedAt: number;
}

/** One OHLCV bucket from GET /pools/:poolId/ohlcv — real venue trade data. */
export interface PriceCandle {
  /** unix seconds (bucket start) */
  t: number;
  o: number;
  h: number;
  l: number;
  c: number;
  volUsd: number;
}

// ----------------------------------------------------------------------------
// GET /pools  → PoolSummary[]
// ----------------------------------------------------------------------------

export interface PoolSummary {
  poolId: PoolId;
  regime: Regime;
  token0: Token;
  token1: Token;
  /** Live dynamic LP fee, hundredths of a bip. Read-through cached, TTL ≤ ~1s (§8). */
  currentFeePips: number;
  /** Trailing fee yield to LPs (net of the 10% perf fee), decimal APR. */
  feeApr: number;
  /** esFERA emissions APR (distinct stream - never blended into feeApr in the UI). */
  emissionsApr: number;
  tvlUsd: number;
  /** Depth multiple vs the best competing vanilla venue for this pair. 1.8 = 1.8x deeper. */
  depthVsBest: number;
  /**
   * Additive (F-8 / D-12): the pool's risk classes. MEME → single Core entry (D-16); RWA →
   * Core + Anchor. When absent the UI treats the pool as single-class Core. `feeApr`/
   * `emissionsApr`/`tvlUsd` above remain the whole-pool blend for list summaries.
   */
  tranches?: TrancheInfo[];
  /**
   * HONESTY FLAG (pre-deployment live mode). `false` = the FERA vault for this pool is
   * NOT deployed: every vault field above (currentFeePips, feeApr, emissionsApr, tvlUsd,
   * depthVsBest) is an inactive zero and MUST render as a quiet "opens at launch" state —
   * never as a number. Absent/`true` = vault numbers are real (indexed on-chain).
   */
  vaultLive?: boolean;
  /** REAL market facts for the underlying venue (present in live mode; always real). */
  market?: PoolMarketStats;
  /**
   * FRONTEND-ONLY overlay (NOT a §8 field — never sent by the API). Attached by
   * lib/hooks/useLivePools.ts when the pool is in config/pools.ts (the deployed
   * registry on chain 4663) and the values were just read from the contracts.
   * Presence ⇒ the vault verifiably exists on-chain for this pool.
   */
  chain?: ChainLiveOverlay;
}

/** Values read straight from the chain (vault + hook), merged over the API/mock row. */
export interface ChainLiveOverlay {
  /**
   * true ⇒ `currentFeePips` IS the real hook fee (FeraHook.getDynamicFee) — render it
   * verbatim, with NO simulated walk (lib/hooks/useLiveFee's walk is mock-only).
   */
  feeLive: boolean;
  /** Tranche-0 NAV in QUOTE TOKENS (decimal-scaled), from FeraVault.quoteNav. */
  navQuote?: number;
  /** Quote-token symbol `navQuote` is denominated in (e.g. "wWETH"). */
  quoteSymbol?: string;
  /**
   * true ⇒ indexer-derived stats (APRs, USD TVL, depth, volume) are NOT available for
   * this pool yet — render "—", never 0. On-chain values (fee, NAV) are still real.
   */
  statsPending?: boolean;
  /** FeraVault.depositsPaused(poolId). */
  depositsPaused?: boolean;
}

// ----------------------------------------------------------------------------
// GET /pools/:poolId  → PoolDetail
// ----------------------------------------------------------------------------

export interface FeeHistoryPoint {
  /** unix seconds */
  t: number;
  /** applied dynamic fee, pips */
  feePips: number;
}

/** MASTER_SPEC §6 StrategyAction.kind (F-8 batch adds 5/6 - D-15/D-17). */
export type StrategyKind =
  | 0 // initialMint (MEME/RWA)
  | 1 // recenter (RWA), or guarded principal recenter (MEME - INV-5″/D-15)
  | 2 // widen (RWA off-hours)
  | 3 // partialWithdraw (RWA)
  | 4 // compoundInPlace
  | 5 // dripDeploy (MEME fee-income deployed into a new band - INV-5″)
  | 6; // bandConsolidate (fee-band merge under MAX_BANDS - D-17)

export interface StrategyLogEntry {
  /** unix seconds */
  t: number;
  kind: StrategyKind;
  tickLower: number;
  tickUpper: number;
  /** oracle price at action time, USD */
  oraclePrice: number;
  /** keccak of the justification payload (INV-6 auditability) */
  justificationHash: `0x${string}`;
  txHash?: `0x${string}`;
}

/**
 * Oracle-anchored band for RWA pools (SHARED_CONTEXT 3). For MEME v2 this describes the
 * *envelope* of the band ladder (`ladder[]` carries the discrete bands). No pool is a single
 * full-range position any more (VAULT_ARCHITECTURE §2.1); `fullRange` on MEME means the
 * always-in-range Tail band still spans full range.
 */
export interface PositionBand {
  fullRange: boolean;
  tickLower?: number;
  tickUpper?: number;
  /** band edges as USD prices, for the live band-vs-oracle chart */
  priceLower?: number;
  priceUpper?: number;
}

/**
 * One discrete band in the vault's shaped ladder (VAULT_ARCHITECTURE §2.1, D-12). MEME
 * principal is minted as Core (k=1.3) / Mid (k=2.0) / Tail (full-range) at 30/40/30
 * (`PARAMS.md#MEME_LADDER_*`); drip adds `fee`-role bands at spot (INV-5″). `weightBps`
 * is the share of principal TVL. Additive §8 field.
 */
export interface LadderBand {
  role: "core" | "mid" | "tail" | "fee";
  /** owning share class (0 = Core, 1 = Anchor). */
  tranche: number;
  /** geometric band factor k: band spans [P/k, P·k]. Absent for full-range tail. */
  k?: number;
  /** share of principal TVL, basis points (Core 3000 / Mid 4000 / Tail 3000). */
  weightBps?: number;
  priceLower?: number;
  priceUpper?: number;
  /** true = principal band (never closed/swapped, INV-5″); false = fee-drip band. */
  isPrincipal: boolean;
  /** at-spot capital-efficiency multiple vs full range (8.13× core, 3.41× mid, 1× tail). */
  depthMult?: number;
}

export interface PoolDetail extends PoolSummary {
  band: PositionBand;
  /** Discrete band ladder (MEME) - additive §8; RWA may omit (single oracle-anchored band). */
  ladder?: LadderBand[];
  /** RWA only. Absent/`null` for MEME. */
  marketHoursState: MarketHoursState | null;
  /** Chainlink feed price, USD. RWA hero; also shown on MEME as reference. */
  oraclePrice: number;
  /** Current pool mid price, USD. */
  poolPrice: number;
  feeHistory: FeeHistoryPoint[];
  strategyLog: StrategyLogEntry[];
}

// ----------------------------------------------------------------------------
// GET /pools/:poolId/depth  → DepthComparison
// ----------------------------------------------------------------------------

export interface VenueDepth {
  venue: string; // "FERA", "Uniswap v3", "Uniswap v4", "Rialto", ...
  /** ±2% depth in USD */
  depthUsd: number;
  isFera?: boolean;
}

export interface DepthComparison {
  poolId: PoolId;
  /** e.g. "NVDA/USDG" */
  pair: string;
  /** Pre-launch (`vaultLive:false`) this is EMPTY — FERA depth doesn't exist yet. */
  venues: VenueDepth[];
  vaultLive?: boolean;
}

// ----------------------------------------------------------------------------
// GET /positions/:account  → Position[]
// ----------------------------------------------------------------------------

export interface Position {
  poolId: PoolId;
  /** which risk class these shares belong to (0 = Core, 1 = Anchor). Additive (D-12). */
  tranche?: number;
  /** raw vault-share balance, decimal-scaled */
  shares: number;
  valueUsd: number;
  /** LP fees earned to date on these shares, USD */
  feesEarned: number;
  /** esFERA accrued & claimable/pending for these shares - 18-dec STRING (§8 v0.2). */
  emissionsPending: string;
  /**
   * Additive: unix-seconds timestamp of this position's last add. Drives the JIT
   * fee-forfeiture window countdown in the Withdraw dialog (INV-1″/D-14). Optional.
   */
  lastAddTs?: number;
}

// ----------------------------------------------------------------------------
// GET /epochs/current  → CurrentEpoch
// ----------------------------------------------------------------------------

export interface CurrentEpoch {
  epochId: number;
  /** unix seconds when this weekly epoch closes */
  endsAt: number;
  /** fees the account PAID as a trader this epoch (drives the 5% trader bucket), USD */
  feesPaid: number;
  /** fees the account EARNED as an LP this epoch (drives the 85% LP bucket), USD */
  feesEarned: number;
  /** projected esFERA for the account at current pro-rata - 18-dec STRING (§8 v0.2). */
  projectedEsFera: string;
  /** `false` = no epochs exist yet (contracts not deployed) — render "starts at launch". */
  vaultLive?: boolean;
}

// ----------------------------------------------------------------------------
// GET /vesting/:account  → VestingGrant[]   (added v0.2, OD-6 / FE-6; §8)
// ----------------------------------------------------------------------------

/**
 * One esFERA vesting grant. §8: `[{ grantId, amount, startTs, endTs, vested, claimable }]`.
 * All esFERA amounts are 18-dec STRINGS (§8 v0.2). esFERA vests ~6mo linear to FERA 1:1;
 * instant-exit on the unvested remainder takes the 50% haircut (INV-9) - see lib/vesting.ts.
 */
export interface VestingGrant {
  grantId: string;
  /** total esFERA granted, 18-dec string. */
  amount: string;
  startTs: number;
  endTs: number;
  /** esFERA vested to date (linear), 18-dec string. */
  vested: string;
  /** FERA claimable right now (vested − already-claimed), 18-dec string. */
  claimable: string;
}

// ----------------------------------------------------------------------------
// GET /epochs/:id/proof/:account  → ClaimProof
// ----------------------------------------------------------------------------

/** MASTER_SPEC §6/§9 Distributor claim kind. */
export type ClaimKind = 0 | 1; // 0 = traderRebate, 1 = lpReward

export interface ClaimProof {
  kind: ClaimKind;
  /** esFERA amount, 18-dec (string to preserve precision on the wire). */
  amount: string;
  proof: `0x${string}`[];
}

// ----------------------------------------------------------------------------
// GET /staking/:account  → StakingSummary
// ----------------------------------------------------------------------------

export interface StakingSummary {
  /** staked FERA balance (sFERA position size) */
  sFera: number;
  /** current boost multiplier on own emissions, ≤ ~2x (§7 Max boost) */
  boost: number;
  /** accrued multiplier points (linearly decaying) */
  multiplierPoints: number;
  /**
   * Revenue-share APR from the 50% staker cut of real protocol revenue.
   * MUST be shown DISTINCTLY from emissions APR (real yield vs token emission).
   */
  revenueShareApr: number;
  /** `false` = staking is not deployed yet — zeros are structural, not balances. */
  vaultLive?: boolean;
}

// ----------------------------------------------------------------------------
// GET /transparency/emissions  → EmissionsTransparency
// ----------------------------------------------------------------------------

export interface EmissionsSeriesPoint {
  epochId: number;
  /** logistic S-curve cap for the epoch (FERA) */
  cap: number;
  /** β × revenueValuedInFera bound for the epoch (FERA) */
  revenueBound: number;
  /** actually emitted = min(cap, revenueBound) (FERA) */
  emitted: number;
  /** manipulation-capped FERA TWAP used to value revenue, USD */
  feraTwap: number;
}

export interface EmissionsTransparency {
  series: EmissionsSeriesPoint[];
}

// ----------------------------------------------------------------------------
// GET /transparency/revenue  → RevenueTransparency
// ----------------------------------------------------------------------------

export interface RevenueByToken {
  token: Token;
  amount: number; // USD
}

export interface RevenueTransparency {
  /** immutable 50/25/25 split - MASTER_SPEC §7 / INV-10 */
  toStakers: number;
  toTreasury: number;
  toOps: number;
  byToken: RevenueByToken[];
}
