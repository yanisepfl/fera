// EsFera handlers — MASTER_SPEC §6: VestStarted, VestClaimed (F-8/D-BK-9), InstantExit,
// ForfeitRouted. Event-log tables only (no aggregates required by §8 yet); INV-9 (forfeiture
// conserves value, 1/3 burn / 1/3 stakers / 1/3 revenue) is reconciled from ForfeitRouted rows by
// ops/ if needed.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { eventId } from "../lib/ids";

ponder.on("EsFera:VestClaimed", async ({ event, context }) => {
  const { account, amount } = event.args;
  await context.db
    .insert(schema.vestClaimed)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      account,
      amount,
      blockNumber: event.block.number,
      timestamp: Number(event.block.timestamp),
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();
});

ponder.on("EsFera:VestStarted", async ({ event, context }) => {
  const { account, amount, startTs, endTs } = event.args;
  await context.db
    .insert(schema.vestStarted)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      account,
      amount,
      startTs,
      endTs,
      blockNumber: event.block.number,
      timestamp: Number(event.block.timestamp),
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();
});

ponder.on("EsFera:InstantExit", async ({ event, context }) => {
  const { account, esBurned, feraOut, haircut } = event.args;
  await context.db
    .insert(schema.instantExit)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      account,
      esBurned,
      feraOut,
      haircut,
      blockNumber: event.block.number,
      timestamp: Number(event.block.timestamp),
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();
});

ponder.on("EsFera:ForfeitRouted", async ({ event, context }) => {
  const { burned, toStakers, toRevenue } = event.args;
  await context.db
    .insert(schema.forfeitRouted)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      burned,
      toStakers,
      toRevenue,
      blockNumber: event.block.number,
      timestamp: Number(event.block.timestamp),
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();
});
