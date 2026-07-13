"use client";

import { useEffect, useState } from "react";
import type { Regime } from "@/lib/types";
import { jitState, feesForfeited, windowLabel, windowCountdown } from "@/lib/jit";
import { usd } from "@/lib/format";
import { cn } from "@/lib/cn";

/**
 * Early-exit fee-forfeiture disclosure (INV-1″ / D-14). Surfaced BEFORE confirm in both the
 * Deposit and Withdraw dialogs, with the same rigor as the esFERA instant-exit haircut: a
 * user must not be able to miss that removing liquidity inside the penalty window forfeits
 * their *accrued fees* (never principal) to the LPs still in range.
 *
 *   mode="deposit"  is a forward-looking rule that WILL apply to this fresh position.
 *   mode="withdraw" is LIVE: given the position's last add + accrued fees, show exactly what
 *                     an exit right now would forfeit, ticking down as the window lapses.
 */
export function JitPenaltyNotice({
  regime,
  mode,
  lastAddTs,
  accruedFeesUsd = 0,
  className,
}: {
  regime: Regime;
  mode: "deposit" | "withdraw";
  lastAddTs?: number;
  accruedFeesUsd?: number;
  className?: string;
}) {
  // Tick every second so the live withdraw countdown/forfeiture stays honest.
  const [, force] = useState(0);
  useEffect(() => {
    if (mode !== "withdraw" || lastAddTs === undefined) return;
    const id = setInterval(() => force((n) => n + 1), 1000);
    return () => clearInterval(id);
  }, [mode, lastAddTs]);

  const win = windowLabel(regime);

  if (mode === "deposit") {
    return (
      <div
        className={cn(
          "rounded-lg border border-warn-wash bg-warn-wash p-3 text-body-sm",
          className
        )}
      >
        <div className="flex items-center gap-1.5">
          <span aria-hidden className="text-warn">⏱</span>
          <span className="font-semibold text-text">
            Early-exit fee forfeiture: {win} window
          </span>
        </div>
        <p className="mt-1 text-caption text-dim">
          If you withdraw within{" "}
          <span className="font-semibold text-text">{win}</span> of a deposit, you forfeit the
          swap fees this position accrued in that window. They go to the LPs still in range.
          The penalty decays linearly to zero across the window. Your{" "}
          <span className="font-semibold text-text">principal is never touched and a
          withdrawal is never blocked</span> (INV-11).
        </p>
        <p className="mt-1.5 text-caption text-pos">
          LP-positive: when other LPs bail early, their forfeited fees are paid to you while
          you stay in range.
        </p>
      </div>
    );
  }

  // withdraw, live
  const s = jitState(regime, lastAddTs);
  const forfeit = feesForfeited(accruedFeesUsd, s);

  if (!s.active) {
    return (
      <div
        className={cn(
          "rounded-lg border border-line bg-well p-3 text-body-sm",
          className
        )}
      >
        <div className="flex items-center gap-1.5 text-pos">
          <span aria-hidden>✓</span>
          <span className="font-semibold">No early-exit penalty</span>
        </div>
        <p className="mt-1 text-caption text-mute">
          This position is past its {win} fee-forfeiture window. You keep 100% of accrued
          fees. (Fees forfeited by LPs who exit early are donated to in-range LPs like you.)
        </p>
      </div>
    );
  }

  const pct = Math.round(s.forfeitFraction * 100);
  return (
    <div
      className={cn(
        "rounded-lg border border-danger-line bg-danger-wash p-4 shadow-glow-danger",
        className
      )}
    >
      <div className="flex items-center justify-between">
        <span className="text-micro font-semibold uppercase tracking-[0.1em] text-danger">
          ⚠ Early-exit forfeiture is active
        </span>
        <span className="font-mono tnum text-body-sm text-danger">−{pct}% of fees</span>
      </div>
      <div className="mt-1 flex items-baseline gap-2">
        <span className="font-mono tnum text-display-l font-bold text-danger">
          {usd(forfeit)}
        </span>
        <span className="text-body text-danger/80">in accrued fees forfeited</span>
      </div>
      <p className="mt-1 text-caption text-danger/80">
        You added this position {win === "30 min" ? "under 30 min" : "under 10 min"} ago.
        Exiting now donates {usd(forfeit)} of your{" "}
        <span className="font-mono">{usd(accruedFeesUsd)}</span> accrued fees to in-range LPs.
        Principal is unaffected.
      </p>
      <div className="mt-2 flex items-center justify-between rounded-md bg-danger-wash/60 px-2 py-1.5">
        <span className="text-caption text-danger/80">Penalty hits zero in</span>
        <span className="font-mono tnum text-body-sm font-semibold text-danger">
          {windowCountdown(s.secondsLeft)}
        </span>
      </div>
      <p className="mt-2 text-caption text-mute">
        Wait it out to keep 100% of your fees. The window decays linearly. Every second you
        hold, less is at risk.
      </p>
    </div>
  );
}
