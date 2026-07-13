/**
 * Mock fixtures — realistic FERA data shaped exactly to MASTER_SPEC §8.
 * Consumed by lib/api.ts in mock mode and by mocks/handlers.ts (MSW).
 * NOT lorem: values reflect the SHARED_CONTEXT thesis (Robinhood Chain pairs,
 * regime fees, weekend Stock-Token drift, emissions ≤ revenue bound).
 */
import type {
  PoolSummary,
  PoolDetail,
  Position,
  CurrentEpoch,
  ClaimProof,
  StakingSummary,
  VestingGrant,
  TrancheInfo,
  LadderBand,
  EmissionsTransparency,
  RevenueTransparency,
  DepthComparison,
  Token,
  FeeHistoryPoint,
  StrategyLogEntry,
  PoolId,
} from "@/lib/types";

const NOW = Math.floor(Date.now() / 1000);
const HOUR = 3600;
const DAY = 86400;

/** Human token count → 18-dec integer STRING (the §8 v0.2 wire format). 812.6 → "812600…000". */
const e18 = (n: number): string => {
  const micro = BigInt(Math.round(n * 1e6)); // keep 6 dp of precision
  return (micro * 10n ** 12n).toString();
};

// --- Tokens (Robinhood Chain) ------------------------------------------------
const WETH: Token = { address: "0x0000000000000000000000000000000000000001", symbol: "WETH", decimals: 18 };
const USDG: Token = { address: "0x0000000000000000000000000000000000000002", symbol: "USDG", decimals: 6 };
const NVDA: Token = { address: "0x0000000000000000000000000000000000000003", symbol: "NVDA", decimals: 18 };
const AAPL: Token = { address: "0x0000000000000000000000000000000000000004", symbol: "AAPL", decimals: 18 };
const GOOG: Token = { address: "0x0000000000000000000000000000000000000005", symbol: "GOOG", decimals: 18 };
const HOOD: Token = { address: "0x0000000000000000000000000000000000000006", symbol: "HOOD", decimals: 18 };
const DOGE: Token = { address: "0x0000000000000000000000000000000000000007", symbol: "DOGE", decimals: 18 };
const PEPE: Token = { address: "0x0000000000000000000000000000000000000008", symbol: "PEPE", decimals: 18 };
const WIF: Token = { address: "0x0000000000000000000000000000000000000009", symbol: "WIF", decimals: 18 };

const pid = (n: number): PoolId =>
  ("0x" + n.toString(16).padStart(64, "0")) as PoolId;

// --- Pool summaries (GET /pools) ---------------------------------------------
export const POOLS: PoolSummary[] = [
  {
    poolId: pid(1),
    regime: "RWA",
    token0: NVDA,
    token1: USDG,
    currentFeePips: 480, // 0.048% — market open, tight
    feeApr: 0.213,
    emissionsApr: 0.116,
    tvlUsd: 4_820_000,
    depthVsBest: 1.82,
  },
  {
    poolId: pid(2),
    regime: "MEME",
    token0: PEPE,
    token1: WETH,
    currentFeePips: 21000, // 2.10% — volatility elevated
    feeApr: 0.734,
    emissionsApr: 0.298,
    tvlUsd: 1_240_000,
    depthVsBest: 1.41,
  },
  {
    poolId: pid(3),
    regime: "RWA",
    token0: AAPL,
    token1: USDG,
    currentFeePips: 520,
    feeApr: 0.188,
    emissionsApr: 0.101,
    tvlUsd: 3_360_000,
    depthVsBest: 1.55,
  },
  {
    poolId: pid(4),
    regime: "MEME",
    token0: WIF,
    token1: WETH,
    currentFeePips: 34000, // 3.40% — one-sided sell pressure
    feeApr: 0.912,
    emissionsApr: 0.377,
    tvlUsd: 690_000,
    depthVsBest: 1.28,
  },
  {
    poolId: pid(5),
    regime: "RWA",
    token0: GOOG,
    token1: USDG,
    currentFeePips: 6200, // 0.62% — market CLOSED, widened
    feeApr: 0.241,
    emissionsApr: 0.094,
    tvlUsd: 2_110_000,
    depthVsBest: 1.36,
  },
  {
    poolId: pid(6),
    regime: "MEME",
    token0: DOGE,
    token1: WETH,
    currentFeePips: 9000, // 0.90%
    feeApr: 0.402,
    emissionsApr: 0.221,
    tvlUsd: 980_000,
    depthVsBest: 1.19,
  },
  {
    poolId: pid(7),
    regime: "RWA",
    token0: HOOD,
    token1: USDG,
    currentFeePips: 610, // off-hours widen
    feeApr: 0.176,
    emissionsApr: 0.088,
    tvlUsd: 1_540_000,
    depthVsBest: 1.22,
  },
];

// --- Risk classes (D-12/D-16) ------------------------------------------------
// Attach the §8 `tranches[]` field. RWA → Active(Core)+Steady(Anchor); MEME → Active only.
// Active concentrates near spot (more fee capture, more IL); Steady sits wide (less of both).
function buildTranches(p: PoolSummary): TrancheInfo[] {
  const core: TrancheInfo = {
    tranche: 0,
    riskClass: "CORE",
    shareSymbol: `fACT-${p.token0.symbol}`,
    feeApr: +(p.feeApr * (p.regime === "MEME" ? 1.0 : 1.28)).toFixed(3),
    emissionsApr: +(p.emissionsApr * (p.regime === "MEME" ? 1.0 : 1.12)).toFixed(3),
    tvlUsd: Math.round(p.tvlUsd * (p.regime === "MEME" ? 1.0 : 0.55)),
  };
  if (p.regime === "MEME") return [core];
  const anchor: TrancheInfo = {
    tranche: 1,
    riskClass: "ANCHOR",
    shareSymbol: `fSTD-${p.token0.symbol}`,
    feeApr: +(p.feeApr * 0.58).toFixed(3),
    emissionsApr: +(p.emissionsApr * 0.82).toFixed(3),
    tvlUsd: Math.round(p.tvlUsd * 0.45),
  };
  return [core, anchor];
}
for (const p of POOLS) p.tranches = buildTranches(p);

/**
 * MEME band ladder (VAULT_ARCHITECTURE §2.1, `PARAMS.md#MEME_LADDER_*`): principal minted as
 * Core (k=1.3) / Mid (k=2.0) / Tail (full range) at 30/40/30, plus fee-drip bands at spot.
 */
function buildMemeLadder(price: number): LadderBand[] {
  const band = (k: number) => ({
    priceLower: +(price / k).toPrecision(4),
    priceUpper: +(price * k).toPrecision(4),
  });
  return [
    { role: "core", tranche: 0, k: 1.3, weightBps: 3000, isPrincipal: true, depthMult: 8.13, ...band(1.3) },
    { role: "mid", tranche: 0, k: 2.0, weightBps: 4000, isPrincipal: true, depthMult: 3.41, ...band(2.0) },
    { role: "tail", tranche: 0, weightBps: 3000, isPrincipal: true, depthMult: 1.0 },
    // fee-drip band (INV-5″): fee income deployed at spot, principal untouched.
    { role: "fee", tranche: 0, k: 1.15, isPrincipal: false, depthMult: 14.3, ...band(1.15) },
  ];
}

// --- Deterministic fee history + strategy logs -------------------------------
function feeHistory(base: number, amp: number, points = 96): FeeHistoryPoint[] {
  const out: FeeHistoryPoint[] = [];
  for (let i = points - 1; i >= 0; i--) {
    const t = NOW - i * HOUR;
    // deterministic pseudo-noise
    const w = Math.sin(i / 6) * 0.5 + Math.sin(i / 2.3) * 0.3 + Math.cos(i / 11) * 0.2;
    const feePips = Math.max(10, Math.round(base + w * amp));
    out.push({ t, feePips });
  }
  return out;
}

const RWA_STRATEGY: StrategyLogEntry[] = [
  {
    t: NOW - 2 * HOUR,
    kind: 2,
    tickLower: -180,
    tickUpper: 180,
    oraclePrice: 121.4,
    justificationHash: "0xa1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00",
    txHash: "0x9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0",
  },
  {
    t: NOW - 20 * HOUR,
    kind: 1,
    tickLower: -60,
    tickUpper: 60,
    oraclePrice: 120.9,
    justificationHash: "0xb2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff0011",
    txHash: "0x8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a09f",
  },
  {
    t: NOW - 3 * DAY,
    kind: 4,
    tickLower: -60,
    tickUpper: 60,
    oraclePrice: 119.2,
    justificationHash: "0xc3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff001122",
  },
  {
    t: NOW - 9 * DAY,
    kind: 0,
    tickLower: -60,
    tickUpper: 60,
    oraclePrice: 116.5,
    justificationHash: "0xd4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00112233",
  },
];

// MEME v2: principal minted once as a ladder; fee income DRIPS to follow price (kind=5);
// rare guarded principal recenter after depth degrades (kind=1); band consolidation (kind=6).
const MEME_STRATEGY: StrategyLogEntry[] = [
  {
    t: NOW - 6 * HOUR,
    kind: 5, // fee drip — principal untouched
    tickLower: -1400,
    tickUpper: 1400,
    oraclePrice: 0,
    justificationHash: "0xe5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff0011223344",
    txHash: "0x71829304a5b6c7d8e9f00112233445566778899aabbccddeeff0011223344556",
  },
  {
    t: NOW - 30 * HOUR,
    kind: 5, // fee drip
    tickLower: -1400,
    tickUpper: 1400,
    oraclePrice: 0,
    justificationHash: "0xa5b6c7d8e9f00112233445566778899aabbccddeeff00112233445566778899aa",
  },
  {
    t: NOW - 4 * DAY,
    kind: 6, // band consolidation — stay under MAX_BANDS (D-17)
    tickLower: -2100,
    tickUpper: 2100,
    oraclePrice: 0,
    justificationHash: "0xb6c7d8e9f00112233445566778899aabbccddeeff00112233445566778899aabb",
  },
  {
    t: NOW - 9 * DAY,
    kind: 1, // guarded principal recenter (rare) — depth stayed below v1 floor ≥24h
    tickLower: -4200,
    tickUpper: 4200,
    oraclePrice: 0,
    justificationHash: "0xc7d8e9f00112233445566778899aabbccddeeff00112233445566778899aabbcc",
    txHash: "0xd8e9f00112233445566778899aabbccddeeff00112233445566778899aabbccdd",
  },
  {
    t: NOW - 12 * DAY,
    kind: 0, // initial ladder mint (Core / Mid / Tail)
    tickLower: -887220,
    tickUpper: 887220,
    oraclePrice: 0,
    justificationHash: "0xf60718293a4b5c6d7e8f90112233445566778899aabbccddeeff001122334455",
    txHash: "0x60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00112233445566",
  },
];

// --- Pool details (GET /pools/:poolId) ---------------------------------------
export const POOL_DETAILS: Record<string, PoolDetail> = {
  [pid(1)]: {
    ...POOLS[0],
    band: { fullRange: false, tickLower: -180, tickUpper: 180, priceLower: 119.1, priceUpper: 123.6 },
    marketHoursState: "OPEN",
    oraclePrice: 121.42,
    poolPrice: 121.55,
    feeHistory: feeHistory(480, 220),
    strategyLog: RWA_STRATEGY,
  },
  [pid(2)]: {
    ...POOLS[1],
    band: { fullRange: true },
    ladder: buildMemeLadder(0.0000112),
    marketHoursState: null,
    oraclePrice: 0,
    poolPrice: 0.0000112,
    feeHistory: feeHistory(21000, 9000),
    strategyLog: MEME_STRATEGY,
  },
  [pid(3)]: {
    ...POOLS[2],
    band: { fullRange: false, tickLower: -120, tickUpper: 120, priceLower: 224.8, priceUpper: 229.9 },
    marketHoursState: "OPEN",
    oraclePrice: 227.3,
    poolPrice: 227.19,
    feeHistory: feeHistory(520, 240),
    strategyLog: RWA_STRATEGY.map((s) => ({ ...s, oraclePrice: s.oraclePrice ? 227 : 0 })),
  },
  [pid(4)]: {
    ...POOLS[3],
    band: { fullRange: true },
    ladder: buildMemeLadder(1.83),
    marketHoursState: null,
    oraclePrice: 0,
    poolPrice: 1.83,
    feeHistory: feeHistory(34000, 12000),
    strategyLog: MEME_STRATEGY,
  },
  [pid(5)]: {
    ...POOLS[4],
    band: { fullRange: false, tickLower: -420, tickUpper: 420, priceLower: 168.2, priceUpper: 176.9 },
    marketHoursState: "CLOSED",
    oraclePrice: 172.6,
    poolPrice: 173.9, // drifted off-hours — arb becomes LP income
    feeHistory: feeHistory(6200, 1400),
    strategyLog: RWA_STRATEGY,
  },
  [pid(6)]: {
    ...POOLS[5],
    band: { fullRange: true },
    ladder: buildMemeLadder(0.164),
    marketHoursState: null,
    oraclePrice: 0,
    poolPrice: 0.164,
    feeHistory: feeHistory(9000, 3800),
    strategyLog: MEME_STRATEGY,
  },
  [pid(7)]: {
    ...POOLS[6],
    band: { fullRange: false, tickLower: -300, tickUpper: 300, priceLower: 88.1, priceUpper: 93.4 },
    marketHoursState: "POST",
    oraclePrice: 90.7,
    poolPrice: 91.2,
    feeHistory: feeHistory(610, 260),
    strategyLog: RWA_STRATEGY,
  },
};

// --- Depth comparison (GET /pools/:poolId/depth) -----------------------------
export const DEPTH: Record<string, DepthComparison> = {
  [pid(1)]: {
    poolId: pid(1),
    pair: "NVDA/USDG",
    venues: [
      { venue: "FERA", depthUsd: 1_420_000, isFera: true },
      { venue: "Uniswap v4", depthUsd: 780_000 },
      { venue: "Uniswap v3", depthUsd: 640_000 },
      { venue: "Rialto", depthUsd: 410_000 },
    ],
  },
  [pid(2)]: {
    poolId: pid(2),
    pair: "PEPE/WETH",
    venues: [
      { venue: "FERA", depthUsd: 512_000, isFera: true },
      { venue: "Uniswap v4", depthUsd: 363_000 },
      { venue: "Uniswap v3", depthUsd: 298_000 },
    ],
  },
};

// --- Positions (GET /positions/:account) -------------------------------------
// emissionsPending is an 18-dec STRING (§8 v0.2). lastAddTs drives the JIT window disclosure:
// pid(2) was just added (inside the 30-min MEME window) → early-exit forfeiture is live.
export const POSITIONS: Position[] = [
  { poolId: pid(1), tranche: 0, shares: 3120.44, valueUsd: 12_840.0, feesEarned: 214.87, emissionsPending: e18(61.2), lastAddTs: NOW - 5 * DAY },
  { poolId: pid(2), tranche: 0, shares: 890.1, valueUsd: 4_210.0, feesEarned: 132.14, emissionsPending: e18(44.9), lastAddTs: NOW - 8 * 60 },
  { poolId: pid(5), tranche: 1, shares: 1540.0, valueUsd: 6_720.0, feesEarned: 88.03, emissionsPending: e18(22.4), lastAddTs: NOW - 20 * DAY },
];

// --- Current epoch (GET /epochs/current) -------------------------------------
export const CURRENT_EPOCH: CurrentEpoch = {
  epochId: 27,
  endsAt: NOW + 2 * DAY + 14 * HOUR + 3 * 60,
  feesPaid: 342.18, // as a trader (drives the 5% trader bucket)
  feesEarned: 435.04, // as an LP (drives the 85% LP bucket)
  projectedEsFera: e18(812.6), // 18-dec string (§8 v0.2)
};

// --- Claim proof (GET /epochs/:id/proof/:account) ----------------------------
export const CLAIM_PROOF: ClaimProof = {
  kind: 1, // lpReward
  amount: "812600000000000000000", // 812.6 esFERA, 18-dec
  proof: [
    "0x1111111111111111111111111111111111111111111111111111111111111111",
    "0x2222222222222222222222222222222222222222222222222222222222222222",
    "0x3333333333333333333333333333333333333333333333333333333333333333",
  ],
};

// --- Staking (GET /staking/:account) -----------------------------------------
export const STAKING: StakingSummary = {
  sFera: 48_200,
  boost: 1.74,
  multiplierPoints: 12_940,
  revenueShareApr: 0.081, // 8.1% REAL yield — shown distinctly from emissions
};

// --- Vesting (GET /vesting/:account) — §8 endpoint added v0.2 (OD-6/FE-6) -----
// Seed grants (human units) → §8 VestingGrant[] with 18-dec STRING amounts. esFERA vests
// ~6mo linear to FERA 1:1 (VEST_DAYS=182). `claimed` = FERA already withdrawn from the grant.
const VEST_SEED = [
  { grantId: "g-24", amount: 1200, startTs: NOW - 40 * DAY, endTs: NOW + 142 * DAY, claimed: 120 },
  { grantId: "g-25", amount: 640, startTs: NOW - 12 * DAY, endTs: NOW + 170 * DAY, claimed: 0 },
  { grantId: "g-26", amount: 812.6, startTs: NOW - 1 * DAY, endTs: NOW + 181 * DAY, claimed: 0 },
];

export const VESTING: VestingGrant[] = VEST_SEED.map((g) => {
  const frac = Math.max(0, Math.min(1, (NOW - g.startTs) / (g.endTs - g.startTs)));
  const vested = g.amount * frac;
  const claimable = Math.max(0, vested - g.claimed);
  return {
    grantId: g.grantId,
    amount: e18(g.amount),
    startTs: g.startTs,
    endTs: g.endTs,
    vested: e18(vested),
    claimable: e18(claimable),
  };
});

// --- Transparency: emissions (GET /transparency/emissions) --------------------
export const EMISSIONS: EmissionsTransparency = {
  series: Array.from({ length: 28 }).map((_, i) => {
    const epochId = i;
    // logistic S-curve cap over ~4y; revenue bound grows with activity then flattens
    const cap = 4_600_000 / (1 + Math.exp(-(i - 14) / 3.2));
    const revenueBound = 120_000 + 62_000 * Math.log(1 + i) + (i % 4) * 9_000;
    const emitted = Math.min(cap, revenueBound); // min(cap, β×revenue) — β folded into revenueBound
    const feraTwap = 0.042 + i * 0.0016 + Math.sin(i / 3) * 0.002;
    return { epochId, cap: Math.round(cap), revenueBound: Math.round(revenueBound), emitted: Math.round(emitted), feraTwap: +feraTwap.toFixed(4) };
  }),
};

// --- Transparency: revenue (GET /transparency/revenue) -----------------------
export const REVENUE: RevenueTransparency = {
  toStakers: 218_400, // 50%
  toTreasury: 109_200, // 25%
  toOps: 109_200, // 25%
  byToken: [
    { token: USDG, amount: 262_000 },
    { token: WETH, amount: 128_500 },
    { token: NVDA, amount: 41_300 },
    { token: AAPL, amount: 5_000 },
  ],
};
