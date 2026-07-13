// RevenueDistributor handlers — MASTER_SPEC §6: RevenueReceived, RevenueSplit.
// Populates event tables + cumulative per-token (revenueByToken) and global (revenueTotals)
// aggregates that power §8 GET /transparency/revenue. INV-10: every inflow splits 50/25/25 with
// no dust escaping — the reconciliation job (ops/) cross-checks this against the chain.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { eventId } from "../lib/ids";

ponder.on("RevenueDistributor:RevenueReceived", async ({ event, context }) => {
  const { token, amount } = event.args;
  const ts = Number(event.block.timestamp);

  await context.db
    .insert(schema.revenueReceived)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      token,
      amount,
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();

  await context.db
    .insert(schema.revenueByToken)
    .values({ id: token.toLowerCase(), token, cumReceived: amount })
    .onConflictDoUpdate((row: { cumReceived: bigint }) => ({ cumReceived: row.cumReceived + amount }));
});

ponder.on("RevenueDistributor:RevenueSplit", async ({ event, context }) => {
  const { token, toStakers, toTreasury, toOps } = event.args;
  const ts = Number(event.block.timestamp);

  await context.db
    .insert(schema.revenueSplit)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      token,
      toStakers,
      toTreasury,
      toOps,
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();

  await context.db
    .insert(schema.revenueByToken)
    .values({ id: token.toLowerCase(), token, cumToStakers: toStakers, cumToTreasury: toTreasury, cumToOps: toOps })
    .onConflictDoUpdate((row: { cumToStakers: bigint; cumToTreasury: bigint; cumToOps: bigint }) => ({
      cumToStakers: row.cumToStakers + toStakers,
      cumToTreasury: row.cumToTreasury + toTreasury,
      cumToOps: row.cumToOps + toOps,
    }));

  await context.db
    .insert(schema.revenueTotals)
    .values({ id: "global", toStakers, toTreasury, toOps })
    .onConflictDoUpdate((row: { toStakers: bigint; toTreasury: bigint; toOps: bigint }) => ({
      toStakers: row.toStakers + toStakers,
      toTreasury: row.toTreasury + toTreasury,
      toOps: row.toOps + toOps,
    }));
});
