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
        marketState === "HOLIDAY" ? "market holiday" : "market closed";
      return {
        headline: `Fee widened: ${venue}`,
        detail:
          "The underlying market is closed, so the price can drift. The range widens and the fee rises - turning that off-hours drift into income for you instead of a loss.",
        tone: "warn",
      };
    }
    return {
      headline: "Low fee: market open",
      detail:
        "While the underlying market is open, the range stays tight and the fee stays low to keep volume flowing.",
      tone: "calm",
    };
  }

  // MEME - fee scales with how volatile trading is.
  const pct = pips / 10_000;
  if (pct >= 2.5) {
    return {
      headline: `Fee ${feePipsToPct(pips)}: high volatility`,
      detail:
        "It's volatile and one-sided out there. The fee is scaled up so the fast, sharp trades that are riskiest to sit against pay the most - and that goes to you.",
      tone: "hot",
    };
  }
  if (pct >= 1.0) {
    return {
      headline: `Fee ${feePipsToPct(pips)}: getting volatile`,
      detail:
        "The market's moving more than usual, so traders pay a higher fee. You earn more right when providing liquidity carries the most risk.",
      tone: "warn",
    };
  }
  return {
    headline: `Fee ${feePipsToPct(pips)}: calm`,
    detail:
      "Trading is quiet, so the fee sits near its floor to keep volume flowing. It rises automatically if the market turns volatile.",
    tone: "calm",
  };
}

export const TONE_COLOR: Record<"calm" | "warn" | "hot", string> = {
  calm: "var(--pos)",
  warn: "var(--warn)",
  hot: "var(--regime-meme)",
};
