/**
 * Wire-format normalizer: Ponder API (backend/api/shapes.ts, "§8 conventions v0.2")
 * → the frontend types in lib/types.ts.
 *
 * WHY: two §8 dialects exist. The devServer/fixtures speak lib/types.ts (numbers,
 * "MEME"/"RWA", `t` timestamps); the Ponder indexer speaks conventions v0.2 (decimal
 * STRINGS for USD/APR, raw-wei strings for token amounts, numeric regime, `timestamp`).
 * Rather than fork the backend's frozen contract (third parties may consume it), every
 * API response passes through these TOLERANT mappers: payloads already in the frontend
 * dialect pass through unchanged, v0.2 payloads are converted. Each mapper documents
 * the fields it reconciles.
 *
 * Best-effort fields (documented inline): values the v0.2 wire cannot express in the
 * frontend unit (e.g. an X96 pool price with no USD reference) normalize to the type's
 * "unavailable" value — never to a fabricated number.
 */
import {
  REGIME_BY_ID,
  RISK_CLASS_BY_TRANCHE,
  type ClaimProof,
  type CurrentEpoch,
  type DepthComparison,
  type EmissionsTransparency,
  type MarketHoursState,
  type PoolDetail,
  type PoolSummary,
  type Position,
  type PositionBand,
  type Regime,
  type RevenueTransparency,
  type StakingSummary,
  type StrategyKind,
  type Token,
  type VestingGrant,
} from "./types";

/* eslint-disable @typescript-eslint/no-explicit-any -- boundary layer over untyped wire JSON */

// ---------------------------------------------------------------------------
// primitives
// ---------------------------------------------------------------------------

/** number | numeric-string → number (fallback on NaN/missing — never NaN into the UI). */
const num = (x: unknown, fallback = 0): number => {
  if (typeof x === "number") return Number.isFinite(x) ? x : fallback;
  if (typeof x === "string" && x.trim() !== "") {
    const n = Number(x);
    if (Number.isFinite(n)) return n;
  }
  return fallback;
};

const optNum = (x: unknown): number | undefined =>
  x === null || x === undefined ? undefined : num(x);

/** Heuristic: a raw 18-dec wei integer string (≥1e13 raw ≈ >0.00001 tokens). */
const isWeiString = (x: unknown): x is string =>
  typeof x === "string" && /^\d{13,}$/.test(x);

/** Raw-wei string → decimal-scaled number (display precision only). */
const weiToNum = (x: unknown, decimals = 18): number =>
  isWeiString(x) ? Number(x) / 10 ** decimals : num(x);

/** v0.2 numeric regime (0/1) or FE string → FE string. */
const regime = (x: unknown): Regime =>
  typeof x === "number" ? REGIME_BY_ID[x] ?? "MEME" : ((x as Regime) ?? "MEME");

/** v0.2 `timestamp` vs FE `t`. */
const ts = (o: any): number => num(o?.t ?? o?.timestamp);

/** v0.2 token.symbol is nullable; FE requires a string. */
const token = (t: any): Token => ({
  address: t?.address ?? "0x0000000000000000000000000000000000000000",
  symbol:
    t?.symbol ??
    (typeof t?.address === "string" ? `${t.address.slice(0, 6)}…` : "?"),
  decimals: num(t?.decimals, 18),
});

// ---------------------------------------------------------------------------
// per-endpoint mappers
// ---------------------------------------------------------------------------

export function normalizePoolSummary(p: any): PoolSummary {
  return {
    ...p,
    regime: regime(p.regime),
    token0: token(p.token0),
    token1: token(p.token1),
    currentFeePips: num(p.currentFeePips),
    feeApr: num(p.feeApr),
    emissionsApr: num(p.emissionsApr),
    tvlUsd: num(p.tvlUsd),
    depthVsBest: num(p.depthVsBest),
    // v0.2 tranches lack riskClass/emissionsApr; synthesize per D-12 (0=Core, 1=Anchor).
    tranches: Array.isArray(p.tranches)
      ? p.tranches.map((tr: any) => ({
          tranche: num(tr.tranche),
          riskClass:
            tr.riskClass ?? RISK_CLASS_BY_TRANCHE[num(tr.tranche)] ?? "CORE",
          ...(tr.shareSymbol ? { shareSymbol: tr.shareSymbol } : {}),
          feeApr: num(tr.feeApr),
          emissionsApr: num(tr.emissionsApr),
          tvlUsd: num(tr.tvlUsd),
        }))
      : undefined,
  };
}

export const normalizePools = (arr: any): PoolSummary[] =>
  (Array.isArray(arr) ? arr : []).map(normalizePoolSummary);

/** v0.2 `positionBand {tickLower|null}` → FE `band {fullRange, tickLower?}`. */
function normalizeBand(d: any): PositionBand {
  if (d.band) return d.band; // already FE dialect
  const pb = d.positionBand ?? {};
  const lower = pb.tickLower ?? null;
  const upper = pb.tickUpper ?? null;
  return {
    fullRange: lower === null || upper === null,
    ...(lower !== null ? { tickLower: num(lower) } : {}),
    ...(upper !== null ? { tickUpper: num(upper) } : {}),
  };
}

export function normalizePoolDetail(d: any): PoolDetail {
  const base = normalizePoolSummary(d);
  // v0.2 serves poolPrice as a raw X96 integer string — inexpressible as USD without a
  // reference price, so it normalizes to 0 ("unavailable"), never a garbage number.
  const poolPriceRaw = d.poolPrice;
  const poolPrice = isWeiString(poolPriceRaw) ? 0 : num(poolPriceRaw);
  return {
    ...base,
    band: normalizeBand(d),
    ladder: d.ladder,
    marketHoursState: (d.marketHoursState
      ? String(d.marketHoursState).toUpperCase()
      : null) as MarketHoursState | null,
    oraclePrice: num(d.oraclePrice),
    poolPrice,
    feeHistory: (d.feeHistory ?? []).map((f: any) => ({
      t: ts(f),
      feePips: num(f.feePips),
    })),
    strategyLog: (d.strategyLog ?? []).map((s: any) => ({
      t: ts(s),
      kind: num(s.kind) as StrategyKind,
      tickLower: num(s.tickLower),
      tickUpper: num(s.tickUpper),
      oraclePrice: num(s.oraclePrice),
      justificationHash: s.justificationHash,
      ...(s.txHash ? { txHash: s.txHash } : {}),
    })),
  };
}

/** v0.2 `{feraDepth1PctUsd, competitors[]}` → FE `{venues[]}`. */
export function normalizeDepth(x: any): DepthComparison {
  if (Array.isArray(x?.venues)) {
    return {
      ...x,
      venues: x.venues.map((v: any) => ({ ...v, depthUsd: num(v.depthUsd) })),
    };
  }
  const dexLabel = (dex: string): string =>
    dex === "univ3" ? "Uniswap v3" : dex === "univ4" ? "Uniswap v4" : dex;
  return {
    poolId: x.poolId,
    pair: x.pair ?? x.pairKey ?? "",
    venues: [
      { venue: "FERA", depthUsd: num(x.feraDepth1PctUsd), isFera: true },
      ...(x.competitors ?? []).map((c: any) => ({
        venue: dexLabel(c.dex),
        depthUsd: num(c.depth1PctUsd),
      })),
    ],
    ...(x.vaultLive !== undefined ? { vaultLive: x.vaultLive } : {}),
  };
}

export const normalizePositions = (arr: any): Position[] =>
  (Array.isArray(arr) ? arr : []).map((p: any) => ({
    poolId: p.poolId,
    ...(p.tranche !== undefined ? { tranche: num(p.tranche) } : {}),
    // v0.2 shares are raw share-wei strings (18-dec clones); FE wants decimal-scaled.
    shares: weiToNum(p.shares),
    valueUsd: num(p.valueUsd),
    feesEarned: num(p.feesEarned),
    emissionsPending: String(p.emissionsPending ?? "0"),
    ...(p.lastAddTs !== undefined ? { lastAddTs: num(p.lastAddTs) } : {}),
  }));

export const normalizeEpoch = (e: any): CurrentEpoch => ({
  epochId: num(e.epochId),
  endsAt: num(e.endsAt),
  feesPaid: num(e.feesPaid),
  feesEarned: num(e.feesEarned),
  projectedEsFera: String(e.projectedEsFera ?? "0"),
  ...(e.vaultLive !== undefined ? { vaultLive: e.vaultLive } : {}),
});

/**
 * v0.2 wraps proof leaves as `{claims: [...]}` (an account can hold both kinds —
 * D-BK-3); FE consumes the singular §8 shape. Prefer the LP-reward leaf.
 */
export function normalizeClaimProof(x: any): ClaimProof {
  if (!x || Array.isArray(x.proof)) return x; // already singular
  const claims: any[] = Array.isArray(x.claims) ? x.claims : [];
  const best = claims.find((c) => num(c.kind) === 1) ?? claims[0];
  return best
    ? { kind: num(best.kind) as 0 | 1, amount: String(best.amount ?? "0"), proof: best.proof ?? [] }
    : { kind: 1, amount: "0", proof: [] };
}

export const normalizeStaking = (s: any): StakingSummary => ({
  sFera: weiToNum(s.sFera),
  boost: num(s.boost, 1),
  multiplierPoints: weiToNum(s.multiplierPoints),
  revenueShareApr: num(s.revenueShareApr),
  ...(s.vaultLive !== undefined ? { vaultLive: s.vaultLive } : {}),
});

/** Shapes agree (strings by design); just harden the numeric timestamps. */
export const normalizeVesting = (arr: any): VestingGrant[] =>
  (Array.isArray(arr) ? arr : []).map((g: any) => ({
    grantId: String(g.grantId),
    amount: String(g.amount ?? "0"),
    startTs: num(g.startTs),
    endTs: num(g.endTs),
    vested: String(g.vested ?? "0"),
    claimable: String(g.claimable ?? "0"),
  }));

export const normalizeEmissions = (x: any): EmissionsTransparency => ({
  series: (x?.series ?? []).map((p: any) => ({
    epochId: num(p.epochId),
    // v0.2 serves FERA amounts as raw-wei strings; FE charts want token units.
    cap: weiToNum(p.cap),
    revenueBound: weiToNum(p.revenueBound),
    emitted: weiToNum(p.emitted),
    feraTwap: num(p.feraTwap),
  })),
});

export function normalizeRevenue(x: any): RevenueTransparency {
  const byToken = (x?.byToken ?? []).map((b: any) =>
    typeof b.token === "string"
      ? {
          // v0.2: token is a bare address + per-leg wei strings; FE wants {Token, amount}.
          token: token({ address: b.token }),
          amount: weiToNum(b.received),
        }
      : { ...b, amount: num(b.amount) }
  );
  return {
    toStakers: weiToNum(x?.toStakers),
    toTreasury: weiToNum(x?.toTreasury),
    toOps: weiToNum(x?.toOps),
    byToken,
  };
}
