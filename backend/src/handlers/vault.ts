// FeraVault handlers — MASTER_SPEC v0.6 §6 (F-8 batch): Deposit, Withdraw, FeesCollected,
// StrategyAction (kind 5 dripDeploy), SharePriceCheckpoint — all tranche-aware (D-12).
// Populates event tables + derived position (per pool per tranche) / tranche / pool /
// epoch aggregates.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { eventId } from "../lib/ids";
import { epochIdForTimestamp } from "../lib/epoch";
import { tokensFor } from "../lib/poolRegistry";
import { toUsdE6 } from "../lib/priceRegistry";

const trancheId = (poolId: string, tranche: number) => `${poolId}:${tranche}`;
const positionId = (poolId: string, tranche: number, user: string) =>
  `${poolId}:${tranche}:${user.toLowerCase()}`;

ponder.on("FeraVault:Deposit", async ({ event, context }) => {
  const { poolId, user, amount0, amount1, sharesMinted, tranche } = event.args;
  const ts = Number(event.block.timestamp);
  const id = eventId(event.block.number, event.log.logIndex);
  const tr = Number(tranche);

  await context.db
    .insert(schema.deposit)
    .values({
      id,
      poolId,
      tranche: tr,
      user,
      amount0,
      amount1,
      sharesMinted,
      epochId: epochIdForTimestamp(ts),
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();

  await context.db
    .insert(schema.position)
    .values({
      id: positionId(poolId, tr, user),
      poolId,
      tranche: tr,
      account: user,
      shares: sharesMinted,
      lastUpdated: ts,
    })
    .onConflictDoUpdate((row) => ({ shares: row.shares + sharesMinted, lastUpdated: ts }));

  // per-tranche supply/reserves (D-12: independent ERC-20 per tranche)
  await context.db
    .insert(schema.tranche)
    .values({
      id: trancheId(poolId, tr),
      poolId,
      tranche: tr,
      totalShares: sharesMinted,
      reserve0: amount0,
      reserve1: amount1,
      lastUpdated: ts,
    })
    .onConflictDoUpdate((row) => ({
      totalShares: row.totalShares + sharesMinted,
      reserve0: row.reserve0 + amount0,
      reserve1: row.reserve1 + amount1,
      lastUpdated: ts,
    }));

  // pool-level rollup (Σ across tranches). token0/token1 are required on insert (the lazy-create
  // path when this event lands before PoolRegistered) — env registry fallback, ZERO if unknown.
  const tk = tokensFor(poolId);
  await context.db
    .insert(schema.pool)
    .values({ id: poolId, token0: tk.token0, token1: tk.token1, totalShares: sharesMinted, reserve0: amount0, reserve1: amount1 })
    .onConflictDoUpdate((row) => ({
      totalShares: row.totalShares + sharesMinted,
      reserve0: row.reserve0 + amount0,
      reserve1: row.reserve1 + amount1,
    }));
});

ponder.on("FeraVault:Withdraw", async ({ event, context }) => {
  const { poolId, user, amount0, amount1, sharesBurned, tranche } = event.args;
  const ts = Number(event.block.timestamp);
  const id = eventId(event.block.number, event.log.logIndex);
  const tr = Number(tranche);

  await context.db
    .insert(schema.withdraw)
    .values({
      id,
      poolId,
      tranche: tr,
      user,
      amount0,
      amount1,
      sharesBurned,
      epochId: epochIdForTimestamp(ts),
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();

  await context.db
    .insert(schema.position)
    .values({ id: positionId(poolId, tr, user), poolId, tranche: tr, account: user, shares: 0n, lastUpdated: ts })
    .onConflictDoUpdate((row) => ({
      shares: row.shares > sharesBurned ? row.shares - sharesBurned : 0n,
      lastUpdated: ts,
    }));

  await context.db
    .insert(schema.tranche)
    .values({ id: trancheId(poolId, tr), poolId, tranche: tr, lastUpdated: ts })
    .onConflictDoUpdate((row) => ({
      totalShares: row.totalShares > sharesBurned ? row.totalShares - sharesBurned : 0n,
      reserve0: row.reserve0 > amount0 ? row.reserve0 - amount0 : 0n,
      reserve1: row.reserve1 > amount1 ? row.reserve1 - amount1 : 0n,
      lastUpdated: ts,
    }));

  const tk = tokensFor(poolId);
  await context.db
    .insert(schema.pool)
    .values({ id: poolId, token0: tk.token0, token1: tk.token1 })
    .onConflictDoUpdate((row) => ({
      totalShares: row.totalShares > sharesBurned ? row.totalShares - sharesBurned : 0n,
      reserve0: row.reserve0 > amount0 ? row.reserve0 - amount0 : 0n,
      reserve1: row.reserve1 > amount1 ? row.reserve1 - amount1 : 0n,
    }));
});

ponder.on("FeraVault:FeesCollected", async ({ event, context }) => {
  const { poolId, fee0, fee1, perfFee0, perfFee1, tranche } = event.args;
  const ts = Number(event.block.timestamp);
  const epochId = epochIdForTimestamp(ts);
  const tr = Number(tranche);
  const tk = tokensFor(poolId);

  // revenue = perf fee (10% skim). net LP = (fee - perfFee). Display-only USD.
  const revenueUsdE6 =
    toUsdE6(tk.token0, perfFee0, tk.token0Decimals) + toUsdE6(tk.token1, perfFee1, tk.token1Decimals);
  const netLpUsdE6 =
    toUsdE6(tk.token0, fee0 - perfFee0, tk.token0Decimals) +
    toUsdE6(tk.token1, fee1 - perfFee1, tk.token1Decimals);

  await context.db
    .insert(schema.feesCollected)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      poolId,
      tranche: tr,
      fee0,
      fee1,
      perfFee0,
      perfFee1,
      revenueUsdE6,
      netLpUsdE6,
      epochId,
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();

  // INV-15: a band's fees accrue solely to its owning tranche.
  await context.db
    .insert(schema.tranche)
    .values({
      id: trancheId(poolId, tr),
      poolId,
      tranche: tr,
      cumFeesUsdE6: netLpUsdE6,
      cumRevenueUsdE6: revenueUsdE6,
      lastUpdated: ts,
    })
    .onConflictDoUpdate((row) => ({
      cumFeesUsdE6: row.cumFeesUsdE6 + netLpUsdE6,
      cumRevenueUsdE6: row.cumRevenueUsdE6 + revenueUsdE6,
      lastUpdated: ts,
    }));

  await context.db
    .insert(schema.pool)
    .values({ id: poolId, token0: tk.token0, token1: tk.token1, cumRevenueUsdE6: revenueUsdE6 })
    .onConflictDoUpdate((row) => ({ cumRevenueUsdE6: row.cumRevenueUsdE6 + revenueUsdE6 }));

  await context.db
    .insert(schema.poolEpochStat)
    .values({ id: `${epochId}:${poolId}`, epochId, poolId, feesEarnedUsdE6: netLpUsdE6, revenueUsdE6 })
    .onConflictDoUpdate((row) => ({
      feesEarnedUsdE6: row.feesEarnedUsdE6 + netLpUsdE6,
      revenueUsdE6: row.revenueUsdE6 + revenueUsdE6,
    }));
});

ponder.on("FeraVault:StrategyAction", async ({ event, context }) => {
  // kind: 0 initialMint 1 recenter 2 widen 3 partialWithdraw 4 compoundInPlace
  //       5 dripDeploy (F-8 — MEME fee-income deployed as a no-swap band, INV-5″)
  //       6 bandConsolidate (F-8 — D-17 fee-band merge; like 5 it does not move principal)
  const { poolId, kind, tickLower, tickUpper, oraclePrice, justificationHash } = event.args;
  const ts = Number(event.block.timestamp);
  const tk = tokensFor(poolId); // lazy-create fallback metadata for the pool upserts below

  await context.db
    .insert(schema.strategyAction)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      poolId,
      kind: Number(kind),
      tickLower: Number(tickLower),
      tickUpper: Number(tickUpper),
      oraclePrice,
      justificationHash,
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();

  // dripDeploy (5) and bandConsolidate (6) touch fee-bands WITHOUT moving principal — do not
  // overwrite the pool's principal band range with them; every other kind updates the headline band.
  if (Number(kind) !== 5 && Number(kind) !== 6) {
    await context.db
      .insert(schema.pool)
      .values({
        id: poolId,
        token0: tk.token0,
        token1: tk.token1,
        tickLower: Number(tickLower),
        tickUpper: Number(tickUpper),
        lastOraclePrice: oraclePrice,
      })
      .onConflictDoUpdate(() => ({
        tickLower: Number(tickLower),
        tickUpper: Number(tickUpper),
        lastOraclePrice: oraclePrice,
      }));
  } else {
    await context.db
      .insert(schema.pool)
      .values({ id: poolId, token0: tk.token0, token1: tk.token1, lastOraclePrice: oraclePrice })
      .onConflictDoUpdate(() => ({ lastOraclePrice: oraclePrice }));
  }
});

ponder.on("FeraVault:SharePriceCheckpoint", async ({ event, context }) => {
  const { poolId, sharePriceX96, epochId, tranche } = event.args;
  const ts = Number(event.block.timestamp);
  const tr = Number(tranche);

  await context.db
    .insert(schema.sharePriceCheckpoint)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      poolId,
      tranche: tr,
      sharePriceX96,
      epochId,
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();

  await context.db
    .insert(schema.tranche)
    .values({ id: trancheId(poolId, tr), poolId, tranche: tr, lastSharePriceX96: sharePriceX96, lastUpdated: ts })
    .onConflictDoUpdate(() => ({ lastSharePriceX96: sharePriceX96, lastUpdated: ts }));

  // pool-level headline mirrors the CORE tranche (0) so INV-4 monitoring keys off one series.
  if (tr === 0) {
    const tk = tokensFor(poolId);
    await context.db
      .insert(schema.pool)
      .values({ id: poolId, token0: tk.token0, token1: tk.token1, lastSharePriceX96: sharePriceX96 })
      .onConflictDoUpdate(() => ({ lastSharePriceX96: sharePriceX96 }));
  }
});
