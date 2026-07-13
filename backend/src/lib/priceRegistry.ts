// Display-only price registry for the INDEXER (D-3 fee→USD conversion for list/detail views).
//
// IMPORTANT: numbers produced here are DISPLAY-ONLY. The consensus-critical emissions pipeline
// (pipeline/) never uses this — it values fees from a PINNED per-epoch price snapshot so the
// Merkle root is reproducible. This registry is a best-effort convenience for the API's tvlUsd /
// feeApr fields, and is a placeholder until wired to Chainlink Data Feeds/Streams reads.
// TODO(spec-freeze): wire to Chainlink feeds from docs/CHAIN.md (per-token feed address map).

import { valueE6, type PriceE6 } from "./prices";

// token address (lowercase) -> USD price E6. Seed from env JSON `FERA_PRICE_REGISTRY_E6`, e.g.
// {"0xweth...":"3000000000","0xusdg...":"1000000"}
function loadRegistry(): Record<string, bigint> {
  const raw = process.env.FERA_PRICE_REGISTRY_E6;
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw) as Record<string, string>;
    const out: Record<string, bigint> = {};
    for (const [k, v] of Object.entries(parsed)) out[k.toLowerCase()] = BigInt(v);
    return out;
  } catch {
    return {};
  }
}

const REGISTRY = loadRegistry();

export function getPriceE6(token: `0x${string}`): PriceE6 {
  return REGISTRY[token.toLowerCase()] ?? 0n;
}

/** Value a raw token amount to USD E6 using the registry (0 if the token price is unknown). */
export function toUsdE6(token: `0x${string}`, amountRaw: bigint, decimals: number): bigint {
  const p = getPriceE6(token);
  if (p === 0n) return 0n;
  return valueE6(amountRaw, p, decimals);
}
