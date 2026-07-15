import type { Regime } from "./types";

/**
 * JIT early-exit fee-forfeiture (INV-1″ / D-14, OZ `LiquidityPenaltyHook` pattern).
 *
 * FERA never blocks or gates a withdrawal (INV-11). Instead, removing liquidity within the
 * penalty window of the position's last add **forfeits that position's accrued swap fees**,
 * which are donated to the LPs still in range. Principal always exits in full. The forfeit
 * decays LINEARLY to zero across the window (MECHANISM_SPEC §3.4):
 *
 *   forfeit = accruedFees × (1 − elapsed / window)
 *
 * Windows are frozen in PARAMS.md#JIT_PENALTY_WINDOW_SEC: MEME 1800s (30 min), RWA 600s
 * (10 min). This is the anti-JIT economics - a bot that adds around a 3% dump fee and
 * removes immediately keeps ≈0 of that fee. The flip side is LP-positive: fees other LPs
 * forfeit when THEY exit early are donated to you while you're in range.
 */
export const JIT_PENALTY_WINDOW_SEC: Record<Regime, number> = {
  MEME: 1800, // 30 min
  RWA: 600, // 10 min
};

export interface JitState {
  /** seconds since the position's last add. */
  elapsed: number;
  /** full penalty window for this regime, seconds. */
  window: number;
  /** true while inside the window (an early exit would forfeit fees). */
  active: boolean;
  /** fraction of accrued fees currently at risk, 0..1 (linear decay). */
  forfeitFraction: number;
  /** seconds until the window fully lapses (0 once past it). */
  secondsLeft: number;
}

export function jitState(
  regime: Regime,
  lastAddTs: number | undefined,
  nowSec = Math.floor(Date.now() / 1000)
): JitState {
  const window = JIT_PENALTY_WINDOW_SEC[regime];
  // No known last-add ⇒ treat as a fresh add (worst case) so the disclosure is never hidden.
  const elapsed = lastAddTs === undefined ? 0 : Math.max(0, nowSec - lastAddTs);
  const active = elapsed < window;
  const forfeitFraction = active ? Math.max(0, 1 - elapsed / window) : 0;
  return {
    elapsed,
    window,
    active,
    forfeitFraction,
    secondsLeft: Math.max(0, window - elapsed),
  };
}

/** esFERA/USD amount of fees that would be forfeited on an early exit right now. */
export function feesForfeited(accruedFees: number, s: JitState): number {
  return Math.max(0, accruedFees) * s.forfeitFraction;
}

/** "30 min" / "10 min" label for the pool's regime. */
export function windowLabel(regime: Regime): string {
  const m = Math.round(JIT_PENALTY_WINDOW_SEC[regime] / 60);
  return `${m} min`;
}

/** "4m 12s left" style countdown for the live window. */
export function windowCountdown(secondsLeft: number): string {
  const m = Math.floor(secondsLeft / 60);
  const s = Math.floor(secondsLeft % 60);
  return `${m}m ${String(s).padStart(2, "0")}s`;
}

/**
 * Deposit → withdraw hold (vault anti-gaming guard) — this is what the vault Deposit and
 * Withdraw dialogs surface, NOT the JIT fee-forfeiture above.
 *
 * After a deposit the vault applies a one-time 1-hour hold before those shares can be
 * withdrawn. It is not a fee and not a penalty: principal is never at risk, and once the
 * hold lapses a withdrawal is always available — in-kind, pro-rata, straight from the pool.
 * Because the hold (1 h) always outlasts the JIT fee window (≤30 min), a vault depositor can
 * never actually land inside the fee-forfeiture window, so the dialogs show the hold instead.
 */
export const DEPOSIT_HOLD_SEC = 3600; // 1 hour

export interface HoldState {
  /** true while the position is still inside its one-time post-deposit hold. */
  held: boolean;
  /** seconds until the hold lapses (0 once past it). */
  secondsLeft: number;
}

export function holdState(
  lastAddTs: number | undefined,
  nowSec = Math.floor(Date.now() / 1000)
): HoldState {
  if (lastAddTs === undefined) return { held: false, secondsLeft: 0 };
  const elapsed = Math.max(0, nowSec - lastAddTs);
  const secondsLeft = Math.max(0, DEPOSIT_HOLD_SEC - elapsed);
  return { held: secondsLeft > 0, secondsLeft };
}

/** "1-hour" style label for the deposit hold, derived from DEPOSIT_HOLD_SEC. */
export const HOLD_LABEL = `${Math.round(DEPOSIT_HOLD_SEC / 3600)}-hour`;
