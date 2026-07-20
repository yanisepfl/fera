import { NextResponse, type NextRequest } from "next/server";
import { geolocation } from "@vercel/functions";
import { REGION_COOKIE } from "@/config/geo";

/**
 * Edge Middleware — RWA geo first-pass.
 *
 * Resolves the visitor's region via Vercel's native edge geolocation (`geolocation()`
 * from `@vercel/functions` — NOT the deprecated `@vercel/edge` / `request.geo`; free on
 * every Vercel plan, zero extra network I/O since it only reads the `x-vercel-ip-*`
 * headers Vercel's edge network already attaches to the request) and stamps the result
 * onto a short-lived, non-httpOnly cookie that config/geo.ts's `resolveRegion()` reads
 * client-side for the instant Tier-1 UI check (blocked banner / ack checkbox).
 *
 * WHY MIDDLEWARE, AND WHY THIS SCOPE (read before "just narrow the matcher further"):
 * the RWA/MEME split in this app is DATA-driven, not ROUTE-driven — `/app` (pool list)
 * and `/app/pool/[poolId]` (pool detail) render BOTH regimes side by side from the same
 * component tree (mixed pool lists; a MEME and an RWA pool share the identical route
 * shape), and regime lives in fixtures/an indexer API, not in anything middleware can
 * see without an extra fetch. So exact path-based "RWA-only" matching isn't possible
 * here — this is the documented SPA-like fallback: middleware stamps a cheap region
 * signal on the routes that CAN show RWA content; the actual RWA-only compliance stack
 * (ipapi.is + Tor exit list + Chainalysis sanctions oracle — see lib/compliance/) is
 * invoked ONLY from the RWA deposit confirm action, never from here and never for MEME:
 *   - useGeoFence (lib/hooks/useGeoFence.ts) short-circuits and returns `allow` for any
 *     non-RWA regime BEFORE it ever calls resolveRegion().
 *   - useRwaComplianceGate (lib/hooks/useRwaComplianceGate.ts) — the hook that calls the
 *     expensive server-side checks — is only invoked from a `pool.regime === "RWA"`
 *     branch in components/earn/DepositDialog.tsx's confirm handlers.
 *
 * COST ON MEME PATHS: within the matched scope below, this file does one header read +
 * one cookie write per request — no fetch, no ipapi.is/Tor/Chainalysis logic (those
 * live exclusively in lib/compliance and are never reached from middleware). That is
 * genuinely negligible even on a MEME pool page, but it is not literally "zero," and
 * this comment says so rather than overclaiming. Every route that can never show an RWA
 * deposit affordance — the marketing site "/", "/legal/*", "/app/rewards", and all
 * static/_next assets — is EXCLUDED by the matcher below, so Next.js never invokes this
 * file for them at all (verified by grepping every DepositDialog call site: PoolRow.tsx,
 * LiveFeeHero.tsx, YourPosition.tsx — all under /app or /app/pool/[poolId] only).
 */
export const config = {
  matcher: ["/app", "/app/pool/:path*"],
};

export function middleware(request: NextRequest) {
  const { country } = geolocation(request);
  const response = NextResponse.next();

  if (country) {
    response.cookies.set(REGION_COOKIE, country.toUpperCase(), {
      maxAge: 60 * 60, // 1h — cheap to re-stamp on the next navigation into /app
      sameSite: "lax",
      path: "/",
      // Readable by client JS on purpose: config/geo.ts#resolveRegion() reads it to
      // drive the instant (Tier-1) UI banner/ack-checkbox. It carries a country code,
      // not a secret. The AUTHORITATIVE check re-derives geolocation server-side from
      // the request itself (lib/compliance/decision.ts) and never trusts this cookie —
      // a tampered cookie can only ever make the Tier-1 UI too lenient, never bypass
      // the real gate.
      httpOnly: false,
    });
  }
  // If country is unresolved (e.g. local dev, not behind Vercel's edge network), we
  // deliberately do NOT set a stale/fake cookie — resolveRegion() falls through to its
  // other hooks (NEXT_PUBLIC_GEO_OVERRIDE, the data-region attribute) or null, and
  // config/geo.ts's `onUnknown` policy decides. Never fabricate a region.
  return response;
}
