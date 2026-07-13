/**
 * Config-driven geo-fencing policy for RWA pools.
 *
 * WHY: RWA pools route liquidity into Robinhood-issued Stock Tokens (NVDA, AAPL…),
 * which carry jurisdictional restrictions that MEME pools do not. FERA never gates
 * SWAPS (INV-2 - routers must reach the pool permissionlessly), so this fence only
 * governs the FRONTEND deposit/LP affordance for RWA regime pools. It is a UI
 * compliance surface, not a protocol control.
 *
 * This is a STUB: region resolution is pluggable. In production, wire `resolveRegion`
 * to an edge/middleware geo header (e.g. Vercel `x-vercel-ip-country`) or Backend's
 * compliance endpoint. Never trust a client-set value for anything on-chain.
 */

export type RegionCode = string; // ISO 3166-1 alpha-2, uppercase

export interface GeoPolicy {
  /** Regimes this policy applies to. MEME pools are never geo-fenced. */
  fencedRegimes: Array<"RWA">;
  /** Regions fully blocked from LPing fenced regimes. */
  blocked: RegionCode[];
  /** Regions allowed but requiring an explicit risk acknowledgement first. */
  requiresAck: RegionCode[];
  /** Fallback when region can't be resolved: "allow" | "ack" | "block". */
  onUnknown: "allow" | "ack" | "block";
}

/**
 * Placeholder policy - values are illustrative and MUST be replaced with a
 * legal-reviewed list before mainnet (tracked in frontend/OPEN_DECISIONS.md OD-4).
 */
export const GEO_POLICY: GeoPolicy = {
  fencedRegimes: ["RWA"],
  blocked: ["US", "CU", "IR", "KP", "SY"],
  requiresAck: ["GB", "CA", "SG"],
  onUnknown: "ack",
};

/**
 * Resolve the viewer's region. STUB order of precedence:
 *   1. NEXT_PUBLIC_GEO_OVERRIDE (local dev / E2E)
 *   2. a region injected by edge middleware onto <html data-region> (prod hook)
 *   3. null → policy.onUnknown decides
 */
export function resolveRegion(): RegionCode | null {
  const override = process.env.NEXT_PUBLIC_GEO_OVERRIDE;
  if (override) return override.toUpperCase();
  if (typeof document !== "undefined") {
    const r = document.documentElement.getAttribute("data-region");
    if (r) return r.toUpperCase();
  }
  return null;
}

export type GeoDecision = "allow" | "ack" | "block";

export function decideGeo(
  region: RegionCode | null,
  policy: GeoPolicy = GEO_POLICY
): { decision: GeoDecision; region: RegionCode | null; reason: string } {
  if (region == null) {
    return {
      decision: policy.onUnknown,
      region,
      reason: "Region could not be determined.",
    };
  }
  if (policy.blocked.includes(region)) {
    return {
      decision: "block",
      region,
      reason: `LP deposits into RWA pools are unavailable in ${region}.`,
    };
  }
  if (policy.requiresAck.includes(region)) {
    return {
      decision: "ack",
      region,
      reason: `RWA (Stock Token) LP positions require a risk acknowledgement in ${region}.`,
    };
  }
  return { decision: "allow", region, reason: "" };
}
