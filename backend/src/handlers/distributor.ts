// Distributor handlers — MASTER_SPEC §6 `RootPosted`, `Claimed`.
import { ponder } from "ponder:registry";
import schema from "ponder:schema";

ponder.on("Distributor:RootPosted", async ({ event, context }) => {
  const { epochId, merkleRoot, totalEsFera } = event.args;
  const ts = Number(event.block.timestamp);

  await context.db
    .insert(schema.epoch)
    .values({
      id: epochId,
      merkleRoot,
      totalEsFera,
      rootPostedBlock: event.block.number,
      rootPostedAt: ts,
    })
    .onConflictDoUpdate(() => ({
      merkleRoot,
      totalEsFera,
      rootPostedBlock: event.block.number,
      rootPostedAt: ts,
    }));
});

ponder.on("Distributor:Claimed", async ({ event, context }) => {
  const { epochId, account, kind, amount } = event.args;
  const ts = Number(event.block.timestamp);
  // id enforces INV-8 (a (epoch,account,kind) claims at most once); onConflictDoNothing is a
  // belt-and-braces guard against a duplicate log after a reorg.
  await context.db
    .insert(schema.claim)
    .values({
      id: `${epochId}:${account.toLowerCase()}:${Number(kind)}`,
      epochId,
      account,
      kind: Number(kind),
      amount,
      blockNumber: event.block.number,
      timestamp: ts,
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();
});
