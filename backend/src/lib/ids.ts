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

/** Lowercased hex address/id that KEEPS the `0x${string}` template type (String.toLowerCase()
 *  widens to `string`, which hex-typed schema columns reject). */
export function lowerHex(h: `0x${string}`): `0x${string}` {
  return h.toLowerCase() as `0x${string}`;
}
