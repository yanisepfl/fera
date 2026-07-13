"use client";

import { useMemo } from "react";
import type { Regime } from "@/lib/types";
import {
  GEO_POLICY,
  decideGeo,
  resolveRegion,
  type GeoDecision,
} from "@/config/geo";

export interface GeoFenceResult {
  /** true when the user may deposit into this pool from the UI. */
  allowed: boolean;
  /** true when a risk-acknowledgement gate must be shown before deposit. */
  needsAck: boolean;
  /** true when fully blocked. */
  blocked: boolean;
  decision: GeoDecision;
  region: string | null;
  reason: string;
}

/**
 * Config-driven geo-fence for a pool's LP/deposit affordance.
 * MEME pools are never fenced; RWA pools consult config/geo.ts.
 * Swaps are NEVER gated by this — INV-2 (routers must reach the pool).
 */
export function useGeoFence(regime: Regime): GeoFenceResult {
  return useMemo(() => {
    const fenced = GEO_POLICY.fencedRegimes.includes(regime as "RWA");
    if (!fenced) {
      return {
        allowed: true,
        needsAck: false,
        blocked: false,
        decision: "allow" as GeoDecision,
        region: null,
        reason: "",
      };
    }
    const region = resolveRegion();
    const { decision, reason } = decideGeo(region, GEO_POLICY);
    return {
      allowed: decision !== "block",
      needsAck: decision === "ack",
      blocked: decision === "block",
      decision,
      region,
      reason,
    };
  }, [regime]);
}
