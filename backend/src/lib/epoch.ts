// Epoch clock helpers. The AUTHORITATIVE epoch boundaries live in EmissionsController (weekly,
// MASTER_SPEC §7). These mirror it for the indexer's convenience (tagging events with epochId
// and computing /epochs/current endsAt). Genesis + length come from env / CHAIN.md.
// TODO(spec-freeze): confirm EMISSIONS_GENESIS_TS and epoch length against EmissionsController.

export const EPOCH_SECONDS = Number(process.env.FERA_EPOCH_SECONDS ?? 7 * 24 * 60 * 60); // 1 week
export const EMISSIONS_GENESIS_TS = Number(process.env.FERA_EMISSIONS_GENESIS_TS ?? 0);

export function epochIdForTimestamp(tsSeconds: number): bigint {
  if (tsSeconds <= EMISSIONS_GENESIS_TS) return 0n;
  return BigInt(Math.floor((tsSeconds - EMISSIONS_GENESIS_TS) / EPOCH_SECONDS));
}

export function epochEndsAt(epochId: bigint): number {
  return EMISSIONS_GENESIS_TS + Number(epochId + 1n) * EPOCH_SECONDS;
}
