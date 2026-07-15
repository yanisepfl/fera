"use client";

import { useEffect, useState } from "react";
import { holdState, windowCountdown, HOLD_LABEL } from "@/lib/jit";
import { cn } from "@/lib/cn";

/**
 * Deposit → withdraw hold notice. Surfaced BEFORE confirm in the vault Deposit and Withdraw
 * dialogs. After a deposit the vault applies a one-time 1-hour hold before those shares can be
 * withdrawn — a standard anti-gaming guard, not a fee and not a penalty. Principal is never at
 * risk; once the hold lapses a withdrawal is always available, in-kind and pro-rata, straight
 * from the pool.
 *
 *   mode="deposit"  forward-looking: the hold that WILL apply to this fresh position.
 *   mode="withdraw" live: whether this position's hold has lapsed yet, ticking down if not.
 */
export function JitPenaltyNotice({
  mode,
  lastAddTs,
  className,
}: {
  mode: "deposit" | "withdraw";
  lastAddTs?: number;
  className?: string;
}) {
  // Tick every second so the live withdraw countdown stays honest.
  const [, force] = useState(0);
  useEffect(() => {
    if (mode !== "withdraw" || lastAddTs === undefined) return;
    const id = setInterval(() => force((n) => n + 1), 1000);
    return () => clearInterval(id);
  }, [mode, lastAddTs]);

  if (mode === "deposit") {
    return (
      <div
        className={cn(
          "rounded-lg border border-line bg-well p-3 text-body-sm",
          className
        )}
      >
        <div className="flex items-center gap-1.5">
          <span aria-hidden className="text-accent">🔒</span>
          <span className="font-semibold text-text">
            Withdraw anytime, after a one-time {HOLD_LABEL} hold
          </span>
        </div>
        <p className="mt-1 text-caption text-dim">
          Right after you deposit there&apos;s a short {HOLD_LABEL} hold before you can
          withdraw — a standard guard that keeps out gamers. Your{" "}
          <span className="font-semibold text-text">deposit is never at risk</span>. Once the
          hold passes you can withdraw anytime, straight from the pool, in-kind: you get your
          share of the actual tokens, with no pricing and nothing to sell.
        </p>
      </div>
    );
  }

  // withdraw — live
  const h = holdState(lastAddTs);

  if (!h.held) {
    return (
      <div
        className={cn(
          "rounded-lg border border-line bg-well p-3 text-body-sm",
          className
        )}
      >
        <div className="flex items-center gap-1.5 text-pos">
          <span aria-hidden>✓</span>
          <span className="font-semibold">Free to withdraw</span>
        </div>
        <p className="mt-1 text-caption text-mute">
          The {HOLD_LABEL} hold has passed. You can withdraw anytime, in-kind and pro-rata —
          your share of the actual pool tokens, straight from the pool. A withdrawal is never
          blocked.
        </p>
      </div>
    );
  }

  return (
    <div
      className={cn(
        "rounded-lg border border-warn-wash bg-warn-wash p-3 text-body-sm",
        className
      )}
    >
      <div className="flex items-center justify-between gap-2">
        <span className="flex items-center gap-1.5 font-semibold text-text">
          <span aria-hidden className="text-warn">⏳</span>
          Short {HOLD_LABEL} hold still in effect
        </span>
        <span className="font-mono tnum text-body-sm text-text">
          {windowCountdown(h.secondsLeft)}
        </span>
      </div>
      <p className="mt-1 text-caption text-dim">
        You deposited recently, so this position is still inside its one-time {HOLD_LABEL}
        hold. You&apos;ll be able to withdraw in{" "}
        <span className="font-semibold text-text">{windowCountdown(h.secondsLeft)}</span>. Your
        deposit is never at risk, and after the hold you can withdraw anytime, in-kind.
      </p>
    </div>
  );
}
