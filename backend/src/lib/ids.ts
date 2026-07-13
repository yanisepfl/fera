// Deterministic ids for idempotent (reorg-safe) event rows.
// `${blockNumber}:${logIndex}` is unique per chain and stable across reprocessing.

export function eventId(blockNumber: bigint, logIndex: number): string {
  return `${blockNumber.toString()}:${logIndex}`;
}

export function pairKey(a: `0x${string}`, b: `0x${string}`): string {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  return x < y ? `${x}:${y}` : `${y}:${x}`;
}
