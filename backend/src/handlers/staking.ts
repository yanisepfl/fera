// AnchorStaking handlers — MASTER_SPEC §6: Staked, Unstaked, RevenueShareClaimed.
// Populates stakingPosition (sFERA balance/lock), stakeEvent (audit log), revenueShareClaimed.
// Powers §8 GET /staking/:account. NOTE: boostX18 + multiplierPoints are point-in-time VIEW reads
// snapshotted by the pipeline at epoch close (they decay continuously and are not derivable from
// events alone), so we track sFERA from events and leave boost/points to be refreshed by a reader.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { eventId, lowerHex } from "../lib/ids";

ponder.on("AnchorStaking:Staked", async ({ event, context }) => {
  const { account, amount } = event.args;
  // Deployed AnchorStaking v2 emits Staked(account, amount) — no lockWeeks field (BK-1
  // reconciliation). Kept as 0 in the row; lock mechanics are not event-sourced on-chain.
  const lockWeeks = 0;
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
      id: lowerHex(account),
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
    .values({ id: lowerHex(account), account, sFera: 0n, lastUpdated: ts })
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
