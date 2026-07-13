// FERA indexer schema (Ponder onchainTable / drizzle). Covers EVERY MASTER_SPEC §6 event plus
// competing vanilla Uniswap v3/v4 pools on the same pairs (depth/fee time-series that powers the
// frontend "LPs earn more per dollar" comparison — §8 /pools/:poolId/depth, verification V4).
//
// Reorg safety: Ponder reverts indexed rows automatically on reorg. Idempotent reprocessing:
// every event row uses a deterministic id = `${chainId}:${blockNumber}:${logIndex}` so a
// re-processed block overwrites rather than duplicates. Aggregates are recomputed from the
// (reorg-safe) event rows, never incremented off-chain-only.
//
// Money amounts are raw bigint (native token decimals). USD is bigint E6 (micro-dollars).

import { onchainTable, index, primaryKey } from "ponder";

// ------------------------------------------------------------------ FERA pools & FeraHook

export const pool = onchainTable("pool", (t) => ({
  id: t.hex().primaryKey(), // v4 PoolId (bytes32)
  regime: t.integer().notNull().default(0), // 0 MEME 1 RWA
  token0: t.hex().notNull(),
  token1: t.hex().notNull(),
  token0Decimals: t.integer().notNull().default(18),
  token1Decimals: t.integer().notNull().default(18),
  token0Symbol: t.text(),
  token1Symbol: t.text(),
  // F-8: true once PoolRegistered (beforeInitialize) has been indexed — token0/token1/regime
  // are then EVENT-SOURCED (BK-2 closed); env FERA_POOL_TOKENS remains the fallback for
  // decimals/symbols (the event carries only addresses + regime).
  registered: t.boolean().notNull().default(false),
  currentFeePips: t.integer().notNull().default(0), // last dynamic LP fee observed in a Swap
  totalShares: t.bigint().notNull().default(0n), // Σ across tranches (per-tranche in `tranche`)
  reserve0: t.bigint().notNull().default(0n),
  reserve1: t.bigint().notNull().default(0n),
  lastSharePriceX96: t.bigint().notNull().default(0n),
  tickLower: t.integer(),
  tickUpper: t.integer(),
  lastOraclePrice: t.bigint().notNull().default(0n),
  marketOpen: t.boolean().notNull().default(true), // RWA market-hours state
  cumFeesUsdE6: t.bigint().notNull().default(0n),
  cumRevenueUsdE6: t.bigint().notNull().default(0n),
  // F-8 JitPenaltyApplied: cumulative fees forfeited by early removers and DONATED to in-range
  // LPs (D-14). This is LP yield — exposed as a pool metric on /pools/:poolId.
  cumJitFee0Forfeited: t.bigint().notNull().default(0n),
  cumJitFee1Forfeited: t.bigint().notNull().default(0n),
  cumJitFeesUsdE6: t.bigint().notNull().default(0n),
  createdBlock: t.bigint().notNull().default(0n),
  createdAt: t.integer().notNull().default(0),
}));

// Per-(pool, tranche) state — F-8/D-12: each tranche is an independent ERC-20 over a disjoint
// band set; share supply, reserves, share price and fee accounting are PER TRANCHE (INV-15).
export const tranche = onchainTable(
  "tranche",
  (t) => ({
    id: t.text().primaryKey(), // `${poolId}:${tranche}`
    poolId: t.hex().notNull(),
    tranche: t.integer().notNull(), // 0 Core, 1 Anchor (≤2 per pool — D-12/D-16)
    totalShares: t.bigint().notNull().default(0n),
    reserve0: t.bigint().notNull().default(0n),
    reserve1: t.bigint().notNull().default(0n),
    lastSharePriceX96: t.bigint().notNull().default(0n),
    cumFeesUsdE6: t.bigint().notNull().default(0n), // net LP fees attributed to this tranche
    cumRevenueUsdE6: t.bigint().notNull().default(0n), // perf-fee skim from this tranche
    lastUpdated: t.integer().notNull().default(0),
  }),
  (table) => ({ poolIdx: index().on(table.poolId) }),
);

export const swap = onchainTable(
  "swap",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    trader: t.hex().notNull(),
    amount0: t.bigint().notNull(),
    amount1: t.bigint().notNull(),
    lpFeePips: t.integer().notNull(),
    feeAmount: t.bigint().notNull(), // LP fee in the INPUT token (raw)
    feeAmountUsdE6: t.bigint().notNull().default(0n), // D-3 conversion
    zeroForOne: t.boolean().notNull(),
    regime: t.integer().notNull(),
    epochId: t.bigint().notNull().default(0n),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    poolIdx: index().on(table.poolId),
    traderIdx: index().on(table.trader),
    epochIdx: index().on(table.epochId),
    tsIdx: index().on(table.timestamp),
  }),
);

export const deposit = onchainTable(
  "deposit",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    tranche: t.integer().notNull().default(0), // F-8 (D-12)
    user: t.hex().notNull(),
    amount0: t.bigint().notNull(),
    amount1: t.bigint().notNull(),
    sharesMinted: t.bigint().notNull(),
    epochId: t.bigint().notNull().default(0n),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    poolIdx: index().on(table.poolId),
    userIdx: index().on(table.user),
    epochIdx: index().on(table.epochId),
  }),
);

export const withdraw = onchainTable(
  "withdraw",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    tranche: t.integer().notNull().default(0), // F-8 (D-12)
    user: t.hex().notNull(),
    amount0: t.bigint().notNull(),
    amount1: t.bigint().notNull(),
    sharesBurned: t.bigint().notNull(),
    epochId: t.bigint().notNull().default(0n),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    poolIdx: index().on(table.poolId),
    userIdx: index().on(table.user),
    epochIdx: index().on(table.epochId),
  }),
);

export const feesCollected = onchainTable(
  "fees_collected",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    tranche: t.integer().notNull().default(0), // F-8 (D-12, INV-15)
    fee0: t.bigint().notNull(),
    fee1: t.bigint().notNull(),
    perfFee0: t.bigint().notNull(),
    perfFee1: t.bigint().notNull(),
    revenueUsdE6: t.bigint().notNull().default(0n), // perf-fee value (protocol revenue)
    netLpUsdE6: t.bigint().notNull().default(0n),
    epochId: t.bigint().notNull().default(0n),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({ poolIdx: index().on(table.poolId), epochIdx: index().on(table.epochId) }),
);

export const strategyAction = onchainTable(
  "strategy_action",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    kind: t.integer().notNull(), // 0 initialMint 1 recenter 2 widen 3 partialWithdraw 4 compoundInPlace 5 dripDeploy (F-8)
    tickLower: t.integer().notNull(),
    tickUpper: t.integer().notNull(),
    oraclePrice: t.bigint().notNull(),
    justificationHash: t.hex().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({ poolIdx: index().on(table.poolId) }),
);

export const sharePriceCheckpoint = onchainTable(
  "share_price_checkpoint",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    tranche: t.integer().notNull().default(0), // F-8 (D-12)
    sharePriceX96: t.bigint().notNull(),
    epochId: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    poolIdx: index().on(table.poolId),
    epochIdx: index().on(table.epochId),
  }),
);

// F-8 JitPenaltyApplied (D-14): early remover forfeits accrued fees, donated to in-range LPs.
// Indexed both as an event log and as pool-level cumulative LP-yield metrics (pool.cumJit*).
export const jitPenalty = onchainTable(
  "jit_penalty",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    owner: t.hex().notNull(), // the penalized remover
    fee0Forfeited: t.bigint().notNull(),
    fee1Forfeited: t.bigint().notNull(),
    forfeitedUsdE6: t.bigint().notNull().default(0n), // display-only valuation
    epochId: t.bigint().notNull().default(0n),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    poolIdx: index().on(table.poolId),
    ownerIdx: index().on(table.owner),
    epochIdx: index().on(table.epochId),
  }),
);

// Per-user vault position (derived from Deposit/Withdraw), PER TRANCHE (F-8/D-12).
// Powers /positions/:account.
export const position = onchainTable(
  "position",
  (t) => ({
    id: t.text().primaryKey(), // `${poolId}:${tranche}:${account}`
    poolId: t.hex().notNull(),
    tranche: t.integer().notNull().default(0),
    account: t.hex().notNull(),
    shares: t.bigint().notNull().default(0n),
    feesEarnedUsdE6: t.bigint().notNull().default(0n),
    lastUpdated: t.integer().notNull().default(0),
  }),
  (table) => ({
    accountIdx: index().on(table.account),
    poolIdx: index().on(table.poolId),
  }),
);

// Dynamic-fee time-series for a FERA pool (feeHistory[] in §8 pool detail).
export const poolFeeSnapshot = onchainTable(
  "pool_fee_snapshot",
  (t) => ({
    id: t.text().primaryKey(), // `${poolId}:${timestamp}`
    poolId: t.hex().notNull(),
    feePips: t.integer().notNull(),
    regime: t.integer().notNull(),
    timestamp: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
  }),
  (table) => ({ poolIdx: index().on(table.poolId), tsIdx: index().on(table.timestamp) }),
);

// ------------------------------------------------------------------ Emissions / Distributor

export const epoch = onchainTable("epoch", (t) => ({
  id: t.bigint().primaryKey(), // epochId
  capAmount: t.bigint().notNull().default(0n),
  revenueBound: t.bigint().notNull().default(0n),
  emitted: t.bigint().notNull().default(0n),
  feraTwap: t.bigint().notNull().default(0n),
  merkleRoot: t.hex(),
  totalEsFera: t.bigint().notNull().default(0n),
  finalizedBlock: t.bigint(),
  finalizedAt: t.integer(),
  rootPostedBlock: t.bigint(),
  rootPostedAt: t.integer(),
  endsAt: t.integer(),
}));

export const claim = onchainTable(
  "claim",
  (t) => ({
    id: t.text().primaryKey(), // `${epochId}:${account}:${kind}` — enforces INV-8 single-claim
    epochId: t.bigint().notNull(),
    account: t.hex().notNull(),
    kind: t.integer().notNull(), // 0 traderRebate 1 lpReward
    amount: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({
    accountIdx: index().on(table.account),
    epochIdx: index().on(table.epochId),
  }),
);

// Per-(epoch, account) running aggregates for the LIVE /epochs/current view (feesPaid,
// feesEarned, projectedEsFera). Authoritative emission amounts come from the pipeline, not here.
export const traderEpochStat = onchainTable(
  "trader_epoch_stat",
  (t) => ({
    id: t.text().primaryKey(), // `${epochId}:${account}`
    epochId: t.bigint().notNull(),
    account: t.hex().notNull(),
    feesPaidUsdE6: t.bigint().notNull().default(0n),
    swapCount: t.integer().notNull().default(0),
  }),
  (table) => ({ epochIdx: index().on(table.epochId), accountIdx: index().on(table.account) }),
);

export const poolEpochStat = onchainTable(
  "pool_epoch_stat",
  (t) => ({
    id: t.text().primaryKey(), // `${epochId}:${poolId}`
    epochId: t.bigint().notNull(),
    poolId: t.hex().notNull(),
    feesPaidUsdE6: t.bigint().notNull().default(0n),
    feesEarnedUsdE6: t.bigint().notNull().default(0n),
    revenueUsdE6: t.bigint().notNull().default(0n),
  }),
  (table) => ({ epochIdx: index().on(table.epochId), poolIdx: index().on(table.poolId) }),
);

// ------------------------------------------------------------------ EsFera

export const vestStarted = onchainTable(
  "vest_started",
  (t) => ({
    id: t.text().primaryKey(),
    account: t.hex().notNull(),
    amount: t.bigint().notNull(),
    startTs: t.bigint().notNull(),
    endTs: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ accountIdx: index().on(table.account) }),
);

export const instantExit = onchainTable(
  "instant_exit",
  (t) => ({
    id: t.text().primaryKey(),
    account: t.hex().notNull(),
    esBurned: t.bigint().notNull(),
    feraOut: t.bigint().notNull(),
    haircut: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ accountIdx: index().on(table.account) }),
);

export const forfeitRouted = onchainTable("forfeit_routed", (t) => ({
  id: t.text().primaryKey(),
  burned: t.bigint().notNull(),
  toStakers: t.bigint().notNull(),
  toRevenue: t.bigint().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.integer().notNull(),
  txHash: t.hex().notNull(),
}));

// F-8 batch (D-BK-9): VestClaimed(account, amount) — lets the indexer track account-level claimed
// esFERA so /vesting can distinguish claimable from vested. Per-grant attribution stays an
// approximation (the event carries no grantId) — see api/store.ts vesting() + OPEN_DECISIONS BK-1.
export const vestClaimed = onchainTable(
  "vest_claimed",
  (t) => ({
    id: t.text().primaryKey(),
    account: t.hex().notNull(),
    amount: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ accountIdx: index().on(table.account) }),
);

// ------------------------------------------------------------------ RevenueDistributor

export const revenueReceived = onchainTable(
  "revenue_received",
  (t) => ({
    id: t.text().primaryKey(),
    token: t.hex().notNull(),
    amount: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ tokenIdx: index().on(table.token) }),
);

export const revenueSplit = onchainTable(
  "revenue_split",
  (t) => ({
    id: t.text().primaryKey(),
    token: t.hex().notNull(),
    toStakers: t.bigint().notNull(),
    toTreasury: t.bigint().notNull(),
    toOps: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ tokenIdx: index().on(table.token) }),
);

// Cumulative revenue per token (powers /transparency/revenue byToken[]).
export const revenueByToken = onchainTable("revenue_by_token", (t) => ({
  id: t.hex().primaryKey(), // token address
  token: t.hex().notNull(),
  cumToStakers: t.bigint().notNull().default(0n),
  cumToTreasury: t.bigint().notNull().default(0n),
  cumToOps: t.bigint().notNull().default(0n),
  cumReceived: t.bigint().notNull().default(0n),
}));

// Global revenue totals (powers /transparency/revenue top level). Singleton row id="global".
export const revenueTotals = onchainTable("revenue_totals", (t) => ({
  id: t.text().primaryKey(),
  toStakers: t.bigint().notNull().default(0n),
  toTreasury: t.bigint().notNull().default(0n),
  toOps: t.bigint().notNull().default(0n),
}));

// ------------------------------------------------------------------ AnchorStaking

export const stakingPosition = onchainTable("staking_position", (t) => ({
  id: t.hex().primaryKey(), // account
  account: t.hex().notNull(),
  sFera: t.bigint().notNull().default(0n),
  lockWeeks: t.integer().notNull().default(0),
  multiplierPoints: t.bigint().notNull().default(0n),
  boostX18: t.bigint().notNull().default(1_000000000000000000n),
  lastUpdated: t.integer().notNull().default(0),
}));

export const stakeEvent = onchainTable(
  "stake_event",
  (t) => ({
    id: t.text().primaryKey(),
    account: t.hex().notNull(),
    kind: t.integer().notNull(), // 0 staked 1 unstaked
    amount: t.bigint().notNull(),
    lockWeeks: t.integer().notNull().default(0),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ accountIdx: index().on(table.account) }),
);

export const revenueShareClaimed = onchainTable(
  "revenue_share_claimed",
  (t) => ({
    id: t.text().primaryKey(),
    account: t.hex().notNull(),
    token: t.hex().notNull(),
    amount: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ accountIdx: index().on(table.account) }),
);

// ------------------------------------------------------------------ Competitor pools (v3/v4)

export const competitorPool = onchainTable(
  "competitor_pool",
  (t) => ({
    id: t.hex().primaryKey(), // v3 pool address OR v4 poolId
    dex: t.text().notNull(), // "univ3" | "univ4"
    token0: t.hex().notNull(),
    token1: t.hex().notNull(),
    feeTier: t.integer().notNull().default(0), // static fee for v3; last observed for v4
    pairKey: t.text().notNull(), // canonical `${min(token0,token1)}:${max}` to join with FERA pools
    liquidity: t.bigint().notNull().default(0n),
    sqrtPriceX96: t.bigint().notNull().default(0n),
    tick: t.integer().notNull().default(0),
    createdBlock: t.bigint().notNull().default(0n),
  }),
  (table) => ({ pairIdx: index().on(table.pairKey), dexIdx: index().on(table.dex) }),
);

export const competitorSwap = onchainTable(
  "competitor_swap",
  (t) => ({
    id: t.text().primaryKey(),
    competitorPoolId: t.hex().notNull(),
    amount0: t.bigint().notNull(),
    amount1: t.bigint().notNull(),
    sqrtPriceX96: t.bigint().notNull(),
    liquidity: t.bigint().notNull(),
    tick: t.integer().notNull(),
    feePips: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({ poolIdx: index().on(table.competitorPoolId), tsIdx: index().on(table.timestamp) }),
);

export const competitorLiquidityEvent = onchainTable(
  "competitor_liquidity_event",
  (t) => ({
    id: t.text().primaryKey(),
    competitorPoolId: t.hex().notNull(),
    kind: t.integer().notNull(), // 0 mint 1 burn 2 modify(v4)
    tickLower: t.integer().notNull(),
    tickUpper: t.integer().notNull(),
    liquidityDelta: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.integer().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({ poolIdx: index().on(table.competitorPoolId) }),
);

// Depth/fee time-series for competitor pools — the marketing comparison series (§8 depth).
export const competitorDepthSnapshot = onchainTable(
  "competitor_depth_snapshot",
  (t) => ({
    id: t.text().primaryKey(), // `${competitorPoolId}:${timestamp}`
    competitorPoolId: t.hex().notNull(),
    pairKey: t.text().notNull(),
    liquidity: t.bigint().notNull(),
    sqrtPriceX96: t.bigint().notNull(),
    tick: t.integer().notNull(),
    feePips: t.integer().notNull(),
    depth1PctUsdE6: t.bigint().notNull().default(0n), // +/-1% depth in USD (computed in handler)
    timestamp: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
  }),
  (table) => ({
    poolIdx: index().on(table.competitorPoolId),
    pairIdx: index().on(table.pairKey),
    tsIdx: index().on(table.timestamp),
  }),
);
