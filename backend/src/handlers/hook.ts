// FeraHook handlers — MASTER_SPEC v0.6 §6: `Swap` (afterSwap), F-8 `PoolRegistered`
// (beforeInitialize — event-sources pool metadata, BK-2) and F-8 `JitPenaltyApplied` (D-14 —
// forfeited fees donated to in-range LPs, indexed as an LP-yield pool metric).
// Populates: pool, swap, poolFeeSnapshot (feeHistory), jitPenalty,
// traderEpochStat + poolEpochStat (feesPaid, powers /epochs/current).

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { eventId } from "../lib/ids";
import { epochIdForTimestamp } from "../lib/epoch";
import { tokensFor, tokenMetaFor } from "../lib/poolRegistry";
import { toUsdE6 } from "../lib/priceRegistry";

// F-8 PoolRegistered — replaces env-sourced pool metadata (env remains the decimals/symbols
// fallback: the event carries only addresses + regime).
ponder.on("FeraHook:PoolRegistered", async ({ event, context }) => {
  const { poolId, token0, token1, regime } = event.args;
  const ts = Number(event.block.timestamp);
  // decimals/symbols: env poolId registry first (complete), then per-address meta, then defaults.
  const envTk = tokensFor(poolId);
  const envMatches = envTk.token0.toLowerCase() === token0.toLowerCase();
  const m0 = tokenMetaFor(token0);
  const m1 = tokenMetaFor(token1);

  await context.db
    .insert(schema.pool)
    .values({
      id: poolId,
      regime: Number(regime),
      token0,
      token1,
      token0Decimals: envMatches ? envTk.token0Decimals : m0.decimals,
      token1Decimals: envMatches ? envTk.token1Decimals : m1.decimals,
      token0Symbol: envMatches ? envTk.token0Symbol : m0.symbol,
      token1Symbol: envMatches ? envTk.token1Symbol : m1.symbol,
      registered: true,
      createdBlock: event.block.number,
      createdAt: ts,
    })
    .onConflictDoUpdate(() => ({
      // event is authoritative for addresses + regime (a Swap may have lazily created the row)
      regime: Number(regime),
      token0,
      token1,
      token0Decimals: envMatches ? envTk.token0Decimals : m0.decimals,
      token1Decimals: envMatches ? envTk.token1Decimals : m1.decimals,
      token0Symbol: envMatches ? envTk.token0Symbol : m0.symbol,
      token1Symbol: envMatches ? envTk.token1Symbol : m1.symbol,
      registered: true,
    }));
});

// F-8 JitPenaltyApplied (D-14): early remover forfeits accrued fees → donated to in-range LPs.
// Forfeited fees are LP YIELD — accumulated on the pool row and served on /pools/:poolId.
ponder.on("FeraHook:JitPenaltyApplied", async ({ event, context }) => {
  const { poolId, owner, fee0Forfeited, fee1Forfeited } = event.args;
  const ts = Number(event.block.timestamp);
  const tk = tokensFor(poolId);
  const usdE6 =
    toUsdE6(tk.token0, fee0Forfeited, tk.token0Decimals) +
    toUsdE6(tk.token1, fee1Forfeited, tk.token1Decimals);

  await context.db
    .insert(schema.jitPenalty)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      poolId,
      owner,
      fee0Forfeited,
      fee1Forfeited,
      forfeitedUsdE6: usdE6,
      epochId: epochIdForTimestamp(ts),
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();

  await context.db
    .insert(schema.pool)
    .values({
      id: poolId,
      token0: tk.token0,
      token1: tk.token1,
      cumJitFee0Forfeited: fee0Forfeited,
      cumJitFee1Forfeited: fee1Forfeited,
      cumJitFeesUsdE6: usdE6,
      createdBlock: event.block.number,
      createdAt: ts,
    })
    .onConflictDoUpdate((row) => ({
      cumJitFee0Forfeited: row.cumJitFee0Forfeited + fee0Forfeited,
      cumJitFee1Forfeited: row.cumJitFee1Forfeited + fee1Forfeited,
      cumJitFeesUsdE6: row.cumJitFeesUsdE6 + usdE6,
    }));
});

ponder.on("FeraHook:Swap", async ({ event, context }) => {
  const { poolId, trader, amount0, amount1, lpFeePips, feeAmount, zeroForOne, regime } =
    event.args;
  const ts = Number(event.block.timestamp);
  const epochId = epochIdForTimestamp(ts);
  const tk = tokensFor(poolId);

  // D-3: feeAmount is in the INPUT token (token0 when zeroForOne). Convert to USD (display-only).
  const inTok = zeroForOne ? tk.token0 : tk.token1;
  const inDec = zeroForOne ? tk.token0Decimals : tk.token1Decimals;
  const feeUsdE6 = toUsdE6(inTok, feeAmount, inDec);

  const id = eventId(event.block.number, event.log.logIndex);
  await context.db
    .insert(schema.swap)
    .values({
      id,
      poolId,
      trader,
      amount0,
      amount1,
      lpFeePips: Number(lpFeePips),
      feeAmount,
      feeAmountUsdE6: feeUsdE6,
      zeroForOne,
      regime: Number(regime),
      epochId,
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();

  // pool: learn regime + latest fee; accumulate fees; create lazily with env token metadata.
  await context.db
    .insert(schema.pool)
    .values({
      id: poolId,
      regime: Number(regime),
      token0: tk.token0,
      token1: tk.token1,
      token0Decimals: tk.token0Decimals,
      token1Decimals: tk.token1Decimals,
      token0Symbol: tk.token0Symbol,
      token1Symbol: tk.token1Symbol,
      currentFeePips: Number(lpFeePips),
      cumFeesUsdE6: feeUsdE6,
      createdBlock: event.block.number,
      createdAt: ts,
    })
    .onConflictDoUpdate((row) => ({
      regime: Number(regime),
      currentFeePips: Number(lpFeePips),
      cumFeesUsdE6: row.cumFeesUsdE6 + feeUsdE6,
    }));

  // fee history point
  await context.db
    .insert(schema.poolFeeSnapshot)
    .values({
      id: `${poolId}:${ts}`,
      poolId,
      feePips: Number(lpFeePips),
      regime: Number(regime),
      timestamp: ts,
      blockNumber: event.block.number,
    })
    .onConflictDoNothing();

  // trader epoch aggregate (feesPaid)
  await context.db
    .insert(schema.traderEpochStat)
    .values({
      id: `${epochId}:${trader.toLowerCase()}`,
      epochId,
      account: trader,
      feesPaidUsdE6: feeUsdE6,
      swapCount: 1,
    })
    .onConflictDoUpdate((row) => ({
      feesPaidUsdE6: row.feesPaidUsdE6 + feeUsdE6,
      swapCount: row.swapCount + 1,
    }));

  // pool epoch aggregate (feesPaid)
  await context.db
    .insert(schema.poolEpochStat)
    .values({
      id: `${epochId}:${poolId}`,
      epochId,
      poolId,
      feesPaidUsdE6: feeUsdE6,
    })
    .onConflictDoUpdate((row) => ({ feesPaidUsdE6: row.feesPaidUsdE6 + feeUsdE6 }));
});
