// LIVE dynamic-fee reader (MASTER_SPEC §8: "Live dynamic fee is read-through cached with TTL ≤
// block time (~100ms → use ~1s practical)").
//
// The dynamic LP fee is computed by FeraHook in `beforeSwap` and is NOT a stored field, so the
// truest "current fee" is an on-chain view (FeraHook.getDynamicFee(poolId)). We call it through a
// per-pool TTL cache (single-flight) so a burst of API traffic collapses to one RPC read per pool
// per ~1s window. If the read fails (RPC hiccup / not deployed), we fall back to the last fee the
// indexer observed in a Swap event (pool.currentFeePips) and mark the source "indexed".

import type { PublicClient } from "viem";
import { FeraHookAbi } from "../abis/FeraHook";
import { TtlCache } from "./cache";
import type { Hex } from "./shapes";

const DEFAULT_TTL_MS = Number(process.env.FERA_LIVE_FEE_TTL_MS ?? 1000); // ≤ ~1s (§8)

export interface LiveFee {
  feePips: number;
  source: "live" | "indexed";
}

export class LiveFeeReader {
  private readonly cache = new TtlCache<number>(DEFAULT_TTL_MS);

  constructor(
    private readonly client: PublicClient | undefined,
    private readonly hookAddress: `0x${string}` | undefined,
  ) {}

  /** Read-through live fee; `indexedFallback` is pool.currentFeePips from the store. */
  async feeFor(poolId: Hex, indexedFallback: number): Promise<LiveFee> {
    if (!this.client || !this.hookAddress || this.hookAddress === "0x0000000000000000000000000000000000000000") {
      return { feePips: indexedFallback, source: "indexed" };
    }
    try {
      const pips = await this.cache.get(poolId, async () => {
        const res = (await this.client!.readContract({
          address: this.hookAddress!,
          abi: FeraHookAbi,
          functionName: "getDynamicFee",
          args: [poolId],
        })) as bigint | number;
        return Number(res);
      });
      return { feePips: pips, source: "live" };
    } catch {
      return { feePips: indexedFallback, source: "indexed" };
    }
  }
}
