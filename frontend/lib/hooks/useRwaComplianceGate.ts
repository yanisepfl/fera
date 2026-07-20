"use client";

import { useCallback, useState } from "react";
import type { RegionCode } from "@/config/geo";

/**
 * Client-side trigger for the server-side RWA compliance gate
 * (lib/compliance/decision.ts, served by app/api/compliance/rwa-check/route.ts).
 *
 * This hook performs NO checks itself — all of the actual logic (ipapi.is, the Tor
 * exit list, the Chainalysis sanctions oracle) runs server-side. `run()` just fires the
 * request at the moment of a real deposit attempt and returns the verdict.
 *
 * ONLY call `run()` from an RWA-regime deposit confirm action (see
 * components/earn/DepositDialog.tsx). Never call it for a MEME pool, and never call it
 * eagerly on mount/render — each call is a real network round trip that (server-side)
 * consumes ipapi.is's free daily quota, so it must correspond to an actual deposit
 * attempt, not a page view.
 */

export type RwaCheckDecision = "allow" | "ack" | "block";

export interface RwaCheckResult {
  decision: RwaCheckDecision;
  region: RegionCode | null;
  reason: string;
}

export interface RwaComplianceGate {
  /** a check is currently in flight. */
  checking: boolean;
  /** the last result, or null before `run()` has ever resolved. */
  result: RwaCheckResult | null;
  /** Fire the compliance check for `address` and resolve with its verdict. */
  run: (address: string) => Promise<RwaCheckResult>;
}

const UNREACHABLE_RESULT: RwaCheckResult = {
  decision: "block",
  region: null,
  reason: "Compliance check failed — please try again.",
};

export function useRwaComplianceGate(): RwaComplianceGate {
  const [checking, setChecking] = useState(false);
  const [result, setResult] = useState<RwaCheckResult | null>(null);

  const run = useCallback(async (address: string): Promise<RwaCheckResult> => {
    setChecking(true);
    try {
      const res = await fetch("/api/compliance/rwa-check", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ address }),
      });
      // Our OWN route handler being unreachable is different from one of the
      // third-party checks INSIDE it failing (those fail open per-check — see
      // lib/compliance/ipapi.ts / torList.ts). If we have no verdict at all from the
      // authoritative gate, fail CLOSED rather than silently letting the deposit
      // through (same convention as lib/tosApi.ts's server-unreachable handling).
      const verdict: RwaCheckResult = res.ok
        ? ((await res.json()) as RwaCheckResult)
        : UNREACHABLE_RESULT;
      setResult(verdict);
      return verdict;
    } catch {
      setResult(UNREACHABLE_RESULT);
      return UNREACHABLE_RESULT;
    } finally {
      setChecking(false);
    }
  }, []);

  return { checking, result, run };
}
