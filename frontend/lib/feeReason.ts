import type { Regime, MarketHoursState } from "./types";
import { feePipsToPct } from "./format";

/**
 * Human "why" for a live dynamic fee. This is the product's core explainability
 * promise: every fee shown says WHY it is what it is (SHARED_CONTEXT §2).
 * Reasons are derived from regime + fee level + RWA market state - the same inputs
 * the hook prices from - so they stay honest to the mechanism.
 */
export function feeReason(
  regime: Regime,
  pips: number,
  marketState?: MarketHoursState | null
): { headline: string; detail: string; tone: "calm" | "warn" | "hot" } {
  if (regime === "RWA") {
    if (marketState && marketState !== "OPEN") {
      const venue =
        marketState === "HOLIDAY" ? "market holiday" : "underlying market closed";
      return {
        headline: `Fee widened: ${venue}`,
        detail:
          "Off-hours the band widens and the fee scales with the pool↔Chainlink gap, so weekend drift arbitrage pays LPs instead of draining them.",
        tone: "warn",
      };
    }
    return {
      headline: "Tight fee: market open",
      detail:
        "During underlying market hours the oracle-anchored band holds a low fee (~1–5bps) and recenters only on oracle hysteresis.",
      tone: "calm",
    };
  }

  // MEME - volatility-scaled
  const pct = pips / 10_000;
  if (pct >= 2.5) {
    return {
      headline: `Fee ${feePipsToPct(pips)}: volatility high`,
      detail:
        "EWMA realized-vol is elevated and net flow is one-sided; the sell-side fee is scaled up so violent/mechanical flow becomes LP income.",
      tone: "hot",
    };
  }
  if (pct >= 1.0) {
    return {
      headline: `Fee ${feePipsToPct(pips)}: volatility elevated`,
      detail:
        "Realized volatility is above baseline. Principal bands aren't churned - IL is compensated by the fee, not chased with active repositioning.",
      tone: "warn",
    };
  }
  return {
    headline: `Fee ${feePipsToPct(pips)}: calm`,
    detail:
      "Realized volatility is near the 0.34% floor. Principal stays put while fee income drips to follow price; the fee rises automatically if flow turns toxic.",
    tone: "calm",
  };
}

export const TONE_COLOR: Record<"calm" | "warn" | "hot", string> = {
  calm: "var(--pos)",
  warn: "var(--warn)",
  hot: "var(--regime-meme)",
};
