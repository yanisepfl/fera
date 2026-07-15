import type { Regime, StrategyKind, MarketHoursState } from "./types";

/** Regime presentation metadata. Colors resolve to CSS vars (see globals.css). */
export const REGIME_META: Record<
  Regime,
  { label: string; color: string; wash: string; blurb: string }
> = {
  MEME: {
    label: "MEME",
    color: "var(--regime-meme)",
    wash: "var(--regime-meme-wash)",
    blurb: "Shaped band ladder. Principal isn't churned; fee income drips to follow price. Volatility-scaled fee turns toxic flow into LP income.",
  },
  RWA: {
    label: "RWA",
    color: "var(--regime-rwa)",
    wash: "var(--regime-rwa-wash)",
    blurb: "Oracle-anchored band. Low fee in market hours, widened off-hours; weekend drift becomes LP yield.",
  },
};

export const STRATEGY_KIND_META: Record<
  StrategyKind,
  { label: string; note: string; principal: boolean }
> = {
  0: { label: "Initial mint", note: "Band ladder opened (Core / Mid / Tail)", principal: true },
  1: {
    label: "Guarded recenter",
    note: "Rare principal move that fires only after at-spot depth stayed below the full-range-equivalent floor for 24h, at least 7 days since the last, and pool TWAP within 5%",
    principal: true,
  },
  2: { label: "Off-hours widen", note: "Underlying market closed; band widened, fee up", principal: true },
  3: { label: "Partial withdraw", note: "Off-hours de-risk", principal: true },
  4: { label: "Compound in place", note: "Fees reinvested into an existing band; no reposition", principal: false },
  5: {
    label: "Fee drip",
    note: "Collected fee income deployed as a new no-swap band at spot; principal untouched",
    principal: false,
  },
  6: { label: "Band consolidate", note: "Nearby fee-bands merged to stay under the band cap", principal: false },
};

export const MARKET_HOURS_META: Record<
  MarketHoursState,
  { label: string; color: string; open: boolean }
> = {
  OPEN: { label: "Market open", color: "var(--pos)", open: true },
  PRE: { label: "Pre-market", color: "var(--warn)", open: false },
  POST: { label: "After-hours", color: "var(--warn)", open: false },
  CLOSED: { label: "Market closed", color: "var(--neg)", open: false },
  HOLIDAY: { label: "Holiday", color: "var(--neg)", open: false },
};
