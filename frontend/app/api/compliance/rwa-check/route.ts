import { NextResponse, type NextRequest } from "next/server";
import { evaluateRwaAccess } from "@/lib/compliance/decision";

/**
 * RWA deposit compliance gate — THIS ENDPOINT AND THE CHECKS IT RUNS ARE NOT A LEGAL
 * SAFE HARBOR. See lib/compliance/decision.ts for the composed logic (priority order,
 * fail-open/fail-closed choices per check) and config/geo.ts for the underlying,
 * PENDING-LEGAL-REVIEW country list.
 *
 * SCOPE: only ever called from the RWA deposit confirm action
 * (components/earn/DepositDialog.tsx, via lib/hooks/useRwaComplianceGate.ts) — never
 * from MEME pool code paths, and never eagerly on page load or pool-list render (that
 * would burn ipapi.is's free 1,000/day quota on page views instead of actual deposit
 * attempts).
 *
 * Edge runtime: matches middleware.ts's runtime, keeps `geolocation()`/`ipAddress()`
 * reading the same Vercel-attached headers, and lets viem's http() transport (used by
 * lib/compliance/sanctionsOracle.ts) run on fetch alone.
 */
export const runtime = "edge";

export async function POST(request: NextRequest) {
  let address: string | undefined;
  try {
    const body = (await request.json()) as { address?: string };
    address = body.address;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }

  if (!address) {
    // Not a compliance verdict — just nothing to screen yet. Distinct, honest reason
    // rather than reusing the sanctions-oracle wording.
    return NextResponse.json(
      {
        decision: "block",
        region: null,
        reason: "Connect a wallet to continue.",
        checks: null,
      },
      { status: 200, headers: { "cache-control": "no-store" } }
    );
  }

  const result = await evaluateRwaAccess(request, address);
  return NextResponse.json(result, { headers: { "cache-control": "no-store" } });
}
