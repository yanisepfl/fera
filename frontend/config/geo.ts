/**
 * Geo-fencing policy for RWA pools — Tier 1 (fast, first-pass) of a two-tier design.
 *
 * WHY: RWA pools route liquidity into Robinhood-issued Stock Tokens (NVDA, AAPL…),
 * which carry jurisdictional restrictions that MEME pools do not. FERA never gates
 * SWAPS (INV-2 - routers must reach the pool permissionlessly), so this fence only
 * governs the FRONTEND deposit/LP affordance for RWA regime pools. It is a UI
 * compliance surface, not a protocol control.
 *
 * TWO-TIER DESIGN:
 *   Tier 1 (this file): a synchronous, client-visible country check. `resolveRegion()`
 *   reads the region Vercel's edge geolocation resolved for this request (stamped onto
 *   a cookie by middleware.ts — see REGION_COOKIE below), giving instant UI feedback (a
 *   blocked banner / ack checkbox) with no network round trip. Country-level
 *   geolocation is known to misfire sometimes (documented in Vercel's own GitHub
 *   issues) — treat this as a fast heuristic, never as proof of jurisdiction.
 *
 *   Tier 2 (frontend/lib/compliance/decision.ts): the AUTHORITATIVE, server-side gate
 *   actually enforced right before an RWA deposit executes. It re-derives geolocation
 *   from the request itself (never trusts the Tier-1 cookie), and adds independent
 *   signals a country code alone can't give you: VPN/Tor/proxy detection (ipapi.is +
 *   the Tor Project's exit list) and wallet sanctions screening (Chainalysis's free
 *   oracle). See that file for the composed decision and its fail-open/fail-closed
 *   reasoning per check.
 *
 * NOT A LEGAL SAFE HARBOR: this is a good-faith, defense-in-depth filter, not a
 * substitute for real KYC/geo counsel. The list below is a reasonable STARTER drawn
 * from public knowledge of where securities-offering rules or OFAC sanctions would make
 * permissionless RWA LPing risky (heavily-regulated securities markets + OFAC-sanctioned
 * jurisdictions) — it still MUST be replaced/confirmed by a legal review before mainnet
 * (tracked as OD-4 in the project's open-decisions log). Keep it as an easily-editable
 * exported constant so that review is a one-line diff, not a code change.
 */

export type RegionCode = string; // ISO 3166-1 alpha-2, uppercase

/** Cookie middleware.ts stamps with the Vercel-resolved region; resolveRegion() reads it. */
export const REGION_COOKIE = "fera-region";

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
 * Starter blocklist — PENDING REAL LEGAL REVIEW (OD-4). Not derived from a licensed
 * compliance database; it's a reasonable first cut covering (a) large jurisdictions
 * where offering tokenized-equity LP positions without local licensing is a known
 * regulatory risk (US, UK, Canada, Switzerland, UAE) and (b) OFAC-sanctioned countries
 * (Cuba, Iran, North Korea, Syria, Russia, Belarus, Sudan, South Sudan, Myanmar,
 * Venezuela). `requiresAck` is intentionally EMPTY: we have no researched basis yet for
 * an "allowed with acknowledgement" tier, so we don't invent one — the mechanism stays
 * available (useGeoFence/DepositDialog already render an ack checkbox) for whenever
 * counsel identifies a real ack-tier region.
 */
export const GEO_POLICY: GeoPolicy = {
  fencedRegimes: ["RWA"],
  blocked: [
    "US", // United States
    "GB", // United Kingdom
    "CA", // Canada
    "CH", // Switzerland
    "AE", // United Arab Emirates
    "CU", // Cuba (OFAC)
    "IR", // Iran (OFAC)
    "KP", // North Korea (OFAC)
    "SY", // Syria (OFAC)
    "RU", // Russia (OFAC)
    "BY", // Belarus (OFAC)
    "SD", // Sudan (OFAC)
    "SS", // South Sudan (OFAC)
    "MM", // Myanmar (OFAC)
    "VE", // Venezuela (OFAC)
  ],
  requiresAck: [],
  onUnknown: "ack",
};

/**
 * Resolve the viewer's region. Order of precedence:
 *   1. NEXT_PUBLIC_GEO_OVERRIDE (local dev / E2E — deterministic, no edge network needed)
 *   2. the `fera-region` cookie stamped by middleware.ts (real Vercel edge geolocation)
 *   3. a `data-region` attribute on <html> (legacy/manual test hook, kept for anything
 *      that sets it directly without going through the cookie)
 *   4. null → policy.onUnknown decides
 *
 * This is the TIER-1 (fast) resolution only — see the file header. It is never trusted
 * for the actual deposit gate; frontend/lib/compliance/decision.ts re-derives region
 * server-side from the request itself.
 */
export function resolveRegion(): RegionCode | null {
  const override = process.env.NEXT_PUBLIC_GEO_OVERRIDE;
  if (override) return override.toUpperCase();

  if (typeof document !== "undefined") {
    const cookieMatch = document.cookie.match(
      new RegExp(`(?:^|; )${REGION_COOKIE}=([^;]+)`)
    );
    if (cookieMatch) return decodeURIComponent(cookieMatch[1]).toUpperCase();

    const attr = document.documentElement.getAttribute("data-region");
    if (attr) return attr.toUpperCase();
  }
  return null;
}

export type GeoDecision = "allow" | "ack" | "block";

/**
 * TIER-1 decision: country code only. Kept synchronous and dependency-free so it can
 * run instantly on render (useGeoFence). The real gate — invoked once, server-side, at
 * the moment of an actual RWA deposit attempt — lives in
 * frontend/lib/compliance/decision.ts#evaluateRwaAccess, which calls this same function
 * again (re-deriving region from the request, not the client-supplied cookie) and layers
 * VPN/Tor and wallet-sanctions checks on top.
 */
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
