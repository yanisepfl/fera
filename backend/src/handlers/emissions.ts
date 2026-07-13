// EmissionsController handler — MASTER_SPEC §6 `EpochFinalized`.
import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { epochEndsAt } from "../lib/epoch";

ponder.on("EmissionsController:EpochFinalized", async ({ event, context }) => {
  const { epochId, capAmount, revenueBound, emitted, feraTwap } = event.args;
  const ts = Number(event.block.timestamp);

  await context.db
    .insert(schema.epoch)
    .values({
      id: epochId,
      capAmount,
      revenueBound,
      emitted,
      feraTwap,
      finalizedBlock: event.block.number,
      finalizedAt: ts,
      endsAt: epochEndsAt(epochId),
    })
    .onConflictDoUpdate(() => ({
      capAmount,
      revenueBound,
      emitted,
      feraTwap,
      finalizedBlock: event.block.number,
      finalizedAt: ts,
    }));
});
