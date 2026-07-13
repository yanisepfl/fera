// AnchorStaking handlers — MASTER_SPEC §6: Staked, Unstaked, RevenueShareClaimed.
// Populates stakingPosition (sFERA balance/lock), stakeEvent (audit log), revenueShareClaimed.
// Powers §8 GET /staking/:account. NOTE: boostX18 + multiplierPoints are point-in-time VIEW reads
// snapshotted by the pipeline at epoch close (they decay continuously and are not derivable from
// events alone), so we track sFERA from events and leave boost/points to be refreshed by a reader.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { eventId } from "../lib/ids";

ponder.on("AnchorStaking:Staked", async ({ event, context }) => {
  const { account, amount, lockWeeks } = event.args;
  const ts = Number(event.block.timestamp);

  await context.db
    .insert(schema.stakeEvent)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      account,
      kind: 0, // staked
      amount,
      lockWeeks: Number(lockWeeks),
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();

  await context.db
    .insert(schema.stakingPosition)
    .values({
      id: account.toLowerCase(),
      account,
      sFera: amount,
      lockWeeks: Number(lockWeeks),
      lastUpdated: ts,
    })
    .onConflictDoUpdate((row: { sFera: bigint }) => ({
      sFera: row.sFera + amount,
      lockWeeks: Number(lockWeeks),
      lastUpdated: ts,
    }));
});

ponder.on("AnchorStaking:Unstaked", async ({ event, context }) => {
  const { account, amount } = event.args;
  const ts = Number(event.block.timestamp);

  await context.db
    .insert(schema.stakeEvent)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      account,
      kind: 1, // unstaked
      amount,
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();

  await context.db
    .insert(schema.stakingPosition)
    .values({ id: account.toLowerCase(), account, sFera: 0n, lastUpdated: ts })
    .onConflictDoUpdate((row: { sFera: bigint }) => ({
      sFera: row.sFera > amount ? row.sFera - amount : 0n,
      lastUpdated: ts,
    }));
});

ponder.on("AnchorStaking:RevenueShareClaimed", async ({ event, context }) => {
  const { account, token, amount } = event.args;
  const ts = Number(event.block.timestamp);

  await context.db
    .insert(schema.revenueShareClaimed)
    .values({
      id: eventId(event.block.number, event.log.logIndex),
      account,
      token,
      amount,
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();
});
