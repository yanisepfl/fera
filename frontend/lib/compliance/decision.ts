/**
 * Composed RWA deposit access decision — SERVER-ONLY, and THIS IS NOT A LEGAL SAFE
 * HARBOR. It is a good-faith, defense-in-depth filter (IP geolocation + VPN/Tor
 * detection + wallet sanctions screening) pending a real KYC/geo program reviewed by
 * counsel — see config/geo.ts's caveat on the underlying country list.
 *
 * Do not import this from a client component. It is only ever called from
 * app/api/compliance/rwa-check/route.ts, which is in turn only ever fetched by
 * lib/hooks/useRwaComplianceGate.ts from an RWA-regime branch in
 * components/earn/DepositDialog.tsx. MEME deposits never reach this file.
 *
 * This is the TIER-2 (authoritative) gate. config/geo.ts's `decideGeo` is the fast,
 * client-visible Tier-1 pass only (country code, no network round trip); this function
 * is the one actually enforced right before an RWA deposit executes. It:
 *   1. re-derives geolocation from the request itself via Vercel's `geolocation()` —
 *      NEVER trusts the Tier-1 cookie a client could have tampered with;
 *   2. runs the two IP-reputation checks (ipapi.is, Tor exit list) in parallel;
 *   3. runs the Chainalysis wallet-sanctions check;
 *   4. composes all four signals into one decision.
 *
 * PRIORITY (most to least severe — first match wins):
 *   1. Sanctioned wallet (Chainalysis), INCLUDING an oracle-unreachable "error" — block.
 *      Fail-closed: see sanctionsOracle.ts. This is checked first and always wins,
 *      regardless of geography — a sanctioned address must never be allowed through.
 *   2. A location-masking IP (VPN/Tor/proxy per ipapi.is, or a Tor Project exit node) —
 *      block. Someone actively hiding their real location from a securities geo-fence is
 *      exactly the case this second pass exists to catch: we can no longer trust ANY
 *      country resolved for this request, so the safe response is to block rather than
 *      guess. (ipapi.is/Tor errors do NOT trigger this branch — see their fail-open
 *      notes; only a definitive "flagged" result does.)
 *   3. Country-level policy (config/geo.ts, re-evaluated here with the
 *      server-authoritative region) — block / ack / allow as configured.
 *   4. Otherwise — allow.
 */

if (typeof window !== "undefined") {
  throw new Error(
    "lib/compliance/decision.ts is server-only and must not be imported into a client bundle"
  );
}

import { geolocation, ipAddress } from "@vercel/functions";
import { GEO_POLICY, decideGeo, type RegionCode } from "@/config/geo";
import { checkIpReputation, type IpReputationResult } from "./ipapi";
import { checkTorExitNode, type TorCheckResult } from "./torList";
import { checkWalletSanctioned, type SanctionsCheckResult } from "./sanctionsOracle";

export type ComplianceDecision = "allow" | "ack" | "block";

export interface RwaAccessResult {
  /** Same {decision, region, reason} shape as config/geo.ts#decideGeo's return, so
   *  existing consumers of that shape (GeoFenceResult) can read this drop-in. */
  decision: ComplianceDecision;
  region: RegionCode | null;
  reason: string;
  /** Additive detail — per-check status, never hidden or fabricated. */
  checks: {
    geo: { region: RegionCode | null; decision: ComplianceDecision };
    ipReputation: IpReputationResult;
    tor: TorCheckResult;
    sanctions: SanctionsCheckResult;
  };
}

const NO_IP_REPUTATION: IpReputationResult = {
  status: "error",
  evasive: false,
  detail: "no client IP resolved for this request",
};

const NO_TOR_CHECK: TorCheckResult = { status: "error", isExitNode: false };

export async function evaluateRwaAccess(
  request: Request,
  walletAddress: string
): Promise<RwaAccessResult> {
  const geo = geolocation(request);
  const region = (geo.country?.toUpperCase() as RegionCode | undefined) ?? null;
  const ip = ipAddress(request);

  const [ipRep, tor, sanctions] = await Promise.all([
    ip ? checkIpReputation(ip) : Promise.resolve(NO_IP_REPUTATION),
    ip ? checkTorExitNode(ip) : Promise.resolve(NO_TOR_CHECK),
    checkWalletSanctioned(walletAddress),
  ]);

  const geoDecision = decideGeo(region, GEO_POLICY);
  const checks: RwaAccessResult["checks"] = {
    geo: { region, decision: geoDecision.decision },
    ipReputation: ipRep,
    tor,
    sanctions,
  };

  // 1. Sanctions — highest priority, fail-closed (see sanctionsOracle.ts).
  if (sanctions.status === "flagged") {
    return {
      decision: "block",
      region,
      reason: "This wallet address is not eligible for RWA deposits.",
      checks,
    };
  }
  if (sanctions.status === "error") {
    return {
      decision: "block",
      region,
      reason: "Sanctions screening is temporarily unavailable. Please try again shortly.",
      checks,
    };
  }

  // 2. Location-masking evasion signal (definitive "flagged" only — errors fail open).
  if (ipRep.evasive || tor.isExitNode) {
    return {
      decision: "block",
      region,
      reason: "RWA deposits aren't available over a VPN, proxy, or Tor connection.",
      checks,
    };
  }

  // 3. Country policy, re-evaluated with the server-authoritative region.
  if (geoDecision.decision !== "allow") {
    return { decision: geoDecision.decision, region, reason: geoDecision.reason, checks };
  }

  // 4. Nothing flagged.
  return { decision: "allow", region, reason: "", checks };
}
