/**
 * ipapi.is IP-reputation second-pass check — SERVER-ONLY.
 *
 * Do not import this from a client component: it makes an outbound fetch with an
 * optional API key (IPAPI_IS_KEY) that must never reach the browser bundle. It is only
 * ever called from lib/compliance/decision.ts, itself only called from
 * app/api/compliance/rwa-check/route.ts.
 *
 * WHY: Vercel's edge geolocation (config/geo.ts, Tier 1) resolves country from IP
 * allocation tables and is known to misfire at the country level (documented in
 * Vercel's own GitHub issues) — it is a fast first pass, not proof of a user's real
 * jurisdiction. ipapi.is adds a second, independent signal: is this IP a VPN/Tor/proxy/
 * known-abuser? Those are exactly the tools someone would use to spoof a "safe" country
 * against the Tier-1 filter.
 *
 * Free tier: 1,000 requests/day, unauthenticated (https://ipapi.is). An optional
 * IPAPI_IS_KEY env var raises the quota; without one this still works. Results are
 * cached 24h per IP (in-memory — fine for a single serverless/edge instance at low RWA
 * traffic; swap for a shared KV/Redis if volume outgrows one instance's cache).
 *
 * FAIL-OPEN BY DESIGN: if the ipapi.is call errors or times out, this check contributes
 * NO signal (status: "error") rather than blocking. Over-blocking a legitimate
 * depositor because a third-party API hiccuped is a real cost too, and the PRIMARY
 * country blocklist (config/geo.ts) still applies regardless of whether this check
 * succeeds — see decision.ts. We never pretend a failed check passed: the caller always
 * sees "error", never a fabricated "ok".
 */

if (typeof window !== "undefined") {
  throw new Error(
    "lib/compliance/ipapi.ts is server-only and must not be imported into a client bundle"
  );
}

interface IpapiIsResponse {
  is_vpn?: boolean;
  is_tor?: boolean;
  is_proxy?: boolean;
  is_datacenter?: boolean;
  is_abuser?: boolean;
}

export type IpReputationStatus = "ok" | "error";

export interface IpReputationResult {
  status: IpReputationStatus;
  /**
   * true if the IP looks like a location-masking tool (VPN/Tor/proxy/known-abuser) —
   * the signal that matters for a geo-fence. `is_datacenter` alone is deliberately NOT
   * treated as evasive here: plenty of legitimate traffic (corporate NAT, cloud-hosted
   * browsers) trips that flag with no evasive intent, so folding it into "evasive"
   * would false-positive too often. Revisit with product/legal if that proves wrong.
   */
  evasive: boolean;
  detail: string;
}

const CACHE_TTL_MS = 24 * 60 * 60 * 1000; // 24h
const FETCH_TIMEOUT_MS = 2500;

const cache = new Map<string, { result: IpReputationResult; expiresAt: number }>();

export async function checkIpReputation(ip: string): Promise<IpReputationResult> {
  const cached = cache.get(ip);
  if (cached && cached.expiresAt > Date.now()) return cached.result;

  const key = process.env.IPAPI_IS_KEY;
  const url = `https://api.ipapi.is/?q=${encodeURIComponent(ip)}${
    key ? `&key=${encodeURIComponent(key)}` : ""
  }`;

  let result: IpReputationResult;
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    let res: Response;
    try {
      res = await fetch(url, {
        signal: controller.signal,
        headers: { accept: "application/json" },
      });
    } finally {
      clearTimeout(timeout);
    }
    if (!res.ok) throw new Error(`ipapi.is responded ${res.status}`);
    const body = (await res.json()) as IpapiIsResponse;
    const evasive = !!(body.is_vpn || body.is_tor || body.is_proxy || body.is_abuser);
    const flags = [
      body.is_vpn && "VPN",
      body.is_tor && "Tor",
      body.is_proxy && "proxy",
      body.is_abuser && "known-abuser",
    ].filter(Boolean);
    result = {
      status: "ok",
      evasive,
      detail: evasive ? `ipapi.is flags this IP as ${flags.join("/")}` : "no evasion signal",
    };
  } catch (err) {
    // FAIL OPEN (see file header): an unreachable/erroring third party contributes no
    // signal — it never turns into an automatic block.
    result = {
      status: "error",
      evasive: false,
      detail: `ipapi.is check unavailable (${err instanceof Error ? err.message : String(err)})`,
    };
  }

  // Only cache a DEFINITIVE answer — a transient error must not "stick" for 24h.
  if (result.status === "ok") {
    cache.set(ip, { result, expiresAt: Date.now() + CACHE_TTL_MS });
  }
  return result;
}
