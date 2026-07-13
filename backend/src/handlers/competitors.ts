// Competitor pool handlers — vanilla Uniswap v3 pools + v4 PoolManager on the SAME pairs as FERA
// pools. Powers §8 GET /pools/:poolId/depth and the verification-V4 "LPs beat vanilla" comparison.
//
// v3: the competitor pool id is the pool ADDRESS (event.log.address). v4: the id is the poolId
// (event.args.id) on the shared PoolManager. Token metadata + canonical pairKey come from the env
// registry (competitorRegistry) since these events don't carry token addresses. depth1PctUsdE6 is
// a documented liquidity-based approximation of ±1% depth (see depth1PctUsdE6 below).

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { competitorMeta } from "../lib/competitorRegistry";
import { getPriceE6 } from "../lib/priceRegistry";
import { valueE6 } from "../lib/prices";

const Q96 = 2n ** 96n;
// sqrt(1.01) ≈ 1.00498756... → integer multiplier (7 sig figs).
const SQRT_1PCT_NUM = 1_004_987n;
const SQRT_1PCT_DEN = 1_000_000n;

/**
 * ±1% depth in USD, APPROXIMATION (documented): the amount of token1 required to push the price
 * +1% assuming constant active liquidity L over that band (Uniswap concentrated-liquidity single-
 * range formula amount1 = L·(√P·√1.01 − √P)/2^96). Valid for deep pools; understates depth where
 * liquidity is concentrated in a tighter band (conservative for the "FERA beats vanilla" claim).
 * TODO(D-BK-4): walk the tick bitmap for exact cross-tick depth.
 */
function depth1PctUsdE6(
  liquidity: bigint,
  sqrtPriceX96: bigint,
  token1: `0x${string}`,
  token1Decimals: number,
): bigint {
  if (liquidity <= 0n || sqrtPriceX96 <= 0n) return 0n;
  const sqrtUpper = (sqrtPriceX96 * SQRT_1PCT_NUM) / SQRT_1PCT_DEN;
  const amount1 = (liquidity * (sqrtUpper - sqrtPriceX96)) / Q96; // raw token1
  const price1 = getPriceE6(token1);
  if (price1 === 0n) return 0n;
  return valueE6(amount1, price1, token1Decimals);
}

async function upsertPoolAndSnapshot(
  context: any,
  id: `0x${string}`,
  dex: "univ3" | "univ4",
  sqrtPriceX96: bigint,
  liquidity: bigint,
  tick: number,
  feePips: number,
  blockNumber: bigint,
  timestamp: number,
) {
  const meta = competitorMeta(id);
  const pairKey = meta?.pairKey ?? "";
  const token1 = meta?.token1 ?? ("0x0000000000000000000000000000000000000000" as `0x${string}`);
  const token1Decimals = meta?.token1Decimals ?? 18;
  const depth = depth1PctUsdE6(liquidity, sqrtPriceX96, token1, token1Decimals);

  await context.db
    .insert(schema.competitorPool)
    .values({
      id,
      dex,
      token0: meta?.token0 ?? "0x0000000000000000000000000000000000000000",
      token1,
      feeTier: meta?.feeTier ?? feePips,
      pairKey,
      liquidity,
      sqrtPriceX96,
      tick,
      createdBlock: blockNumber,
    })
    .onConflictDoUpdate(() => ({ liquidity, sqrtPriceX96, tick, feeTier: meta?.feeTier ?? feePips }));

  await context.db
    .insert(schema.competitorDepthSnapshot)
    .values({
      id: `${id}:${timestamp}`,
      competitorPoolId: id,
      pairKey,
      liquidity,
      sqrtPriceX96,
      tick,
      feePips,
      depth1PctUsdE6: depth,
      timestamp,
      blockNumber,
    })
    .onConflictDoNothing();
}

// ---- Uniswap v3 competitor pools -----------------------------------------------------------

ponder.on("UniswapV3Competitor:Swap", async ({ event, context }) => {
  const id = event.log.address as `0x${string}`;
  const ts = Number(event.block.timestamp);
  const { amount0, amount1, sqrtPriceX96, liquidity, tick } = event.args;
  const feePips = competitorMeta(id)?.feeTier ?? 0;

  await context.db
    .insert(schema.competitorSwap)
    .values({
      id: `${event.block.number}:${event.log.logIndex}`,
      competitorPoolId: id,
      amount0,
      amount1,
      sqrtPriceX96,
      liquidity,
      tick: Number(tick),
      feePips,
      blockNumber: event.block.number,
      timestamp: ts,
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();

  await upsertPoolAndSnapshot(context, id, "univ3", sqrtPriceX96, liquidity, Number(tick), feePips, event.block.number, ts);
});

ponder.on("UniswapV3Competitor:Mint", async ({ event, context }) => {
  const id = event.log.address as `0x${string}`;
  await context.db
    .insert(schema.competitorLiquidityEvent)
    .values({
      id: `${event.block.number}:${event.log.logIndex}`,
      competitorPoolId: id,
      kind: 0, // mint
      tickLower: Number(event.args.tickLower),
      tickUpper: Number(event.args.tickUpper),
      liquidityDelta: event.args.amount,
      blockNumber: event.block.number,
      timestamp: Number(event.block.timestamp),
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();
});

ponder.on("UniswapV3Competitor:Burn", async ({ event, context }) => {
  const id = event.log.address as `0x${string}`;
  await context.db
    .insert(schema.competitorLiquidityEvent)
    .values({
      id: `${event.block.number}:${event.log.logIndex}`,
      competitorPoolId: id,
      kind: 1, // burn
      tickLower: Number(event.args.tickLower),
      tickUpper: Number(event.args.tickUpper),
      liquidityDelta: -event.args.amount,
      blockNumber: event.block.number,
      timestamp: Number(event.block.timestamp),
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();
});

// ---- Uniswap v4 competitor pools (shared PoolManager, filtered by poolId via the registry) ----

ponder.on("UniswapV4PoolManager:Swap", async ({ event, context }) => {
  const id = event.args.id as `0x${string}`;
  if (!competitorMeta(id)) return; // only index poolIds we benchmark (registry allowlist)
  const ts = Number(event.block.timestamp);
  const { amount0, amount1, sqrtPriceX96, liquidity, tick, fee } = event.args;

  await context.db
    .insert(schema.competitorSwap)
    .values({
      id: `${event.block.number}:${event.log.logIndex}`,
      competitorPoolId: id,
      amount0,
      amount1,
      sqrtPriceX96,
      liquidity,
      tick: Number(tick),
      feePips: Number(fee),
      blockNumber: event.block.number,
      timestamp: ts,
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();

  await upsertPoolAndSnapshot(context, id, "univ4", sqrtPriceX96, liquidity, Number(tick), Number(fee), event.block.number, ts);
});

ponder.on("UniswapV4PoolManager:ModifyLiquidity", async ({ event, context }) => {
  const id = event.args.id as `0x${string}`;
  if (!competitorMeta(id)) return;
  await context.db
    .insert(schema.competitorLiquidityEvent)
    .values({
      id: `${event.block.number}:${event.log.logIndex}`,
      competitorPoolId: id,
      kind: 2, // modify (v4)
      tickLower: Number(event.args.tickLower),
      tickUpper: Number(event.args.tickUpper),
      liquidityDelta: event.args.liquidityDelta,
      blockNumber: event.block.number,
      timestamp: Number(event.block.timestamp),
      logIndex: event.log.logIndex,
    })
    .onConflictDoNothing();
});
