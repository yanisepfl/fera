"use client";

import { useEffect, useRef, useState } from "react";
import type { Regime } from "@/lib/types";

/**
 * Simulated LIVE dynamic fee.
 *
 * In production this polls Backend's read-through-cached fee (TTL ≤ ~1s, §8) or a
 * websocket. Here it evolves the seed fee with a small bounded random walk on an
 * interval so the hero number genuinely updates, respecting per-regime structural
 * ranges (MASTER_SPEC §5): MEME [~0.30%, ~5%] → 3000..50000 pips,
 * RWA [~1bp, ~100bp] → 100..10000 pips.
 *
 * SSR-safe: the first render returns the seed unchanged; the walk only starts after
 * mount, so server and client HTML match (no hydration flash) and it idles under
 * prefers-reduced-motion.
 *
 * MEME floor is 3400 pips (0.34%) — raised from 0.30% in Mechanism v2 (PT-3): the 10%
 * perf fee means 0.9·0.34% > 0.30% clears the vanilla-30 hurdle at the floor itself.
 */
const RANGE: Record<Regime, [number, number]> = {
  MEME: [3400, 50000],
  RWA: [100, 10000],
};

export interface LiveFee {
  pips: number;
  prevPips: number;
  /** 1 = ticked up, -1 = down, 0 = unchanged (first paint) */
  direction: -1 | 0 | 1;
  /** monotonically increases each tick — use as a React key to retrigger flash anim */
  tick: number;
}

export function useLiveFee(seedPips: number, regime: Regime, intervalMs = 1600): LiveFee {
  const [state, setState] = useState<LiveFee>({
    pips: seedPips,
    prevPips: seedPips,
    direction: 0,
    tick: 0,
  });
  const current = useRef(seedPips);

  useEffect(() => {
    const [lo, hi] = RANGE[regime];
    const reduce =
      typeof window !== "undefined" &&
      window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    if (reduce) return;

    const id = setInterval(() => {
      const prev = current.current;
      // step ≈ ±0.8% of range, mean-reverting toward the seed
      const span = hi - lo;
      const drift = (seedPips - prev) * 0.05;
      const noise = (Math.random() - 0.5) * span * 0.016;
      let next = Math.round(prev + drift + noise);
      next = Math.max(lo, Math.min(hi, next));
      current.current = next;
      setState((s) => ({
        pips: next,
        prevPips: prev,
        direction: next > prev ? 1 : next < prev ? -1 : 0,
        tick: s.tick + 1,
      }));
    }, intervalMs);
    return () => clearInterval(id);
  }, [seedPips, regime, intervalMs]);

  return state;
}
