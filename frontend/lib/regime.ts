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
    blurb: "Your position is spread across a shaped range and left in place; the fees it earns are redeployed to follow the price. The fee rises with volatility, turning busy, bot-driven trading into income for you.",
  },
  RWA: {
    label: "Stock",
    color: "var(--regime-rwa)",
    wash: "var(--regime-rwa-wash)",
    blurb: "Tokenized stock. The range stays tight while the market is open and widens off-hours, so weekend price drift becomes income for you.",
  },
};

export const STRATEGY_KIND_META: Record<
  StrategyKind,
  { label: string; note: string; principal: boolean }
> = {
  0: { label: "Position opened", note: "Your position opened across a shaped range (Core / Mid / Tail).", principal: true },
  1: {
    label: "Safety-checked reset",
    note: "Rare reset of your position - allowed only after your range stayed too shallow for 24h, at least 7 days since the last reset, and the pool price within 5% of a recent average.",
    principal: true,
  },
  2: { label: "Off-hours widen", note: "Underlying market closed; the range widened and the fee went up.", principal: true },
  3: { label: "Partial withdraw", note: "Off-hours de-risk.", principal: true },
  4: { label: "Fees reinvested", note: "Fees reinvested into your existing range; nothing repositioned.", principal: false },
  5: {
    label: "Fees redeployed",
    note: "Collected fees added as fresh liquidity at the current price; your original deposit untouched.",
    principal: false,
  },
  6: { label: "Ranges merged", note: "Nearby fee ranges merged to keep the position tidy.", principal: false },
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
