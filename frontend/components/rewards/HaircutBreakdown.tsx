"use client";

import { haircut } from "@/lib/vesting";
import { tokenAmt } from "@/lib/format";

/**
 * The instant-exit tradeoff, kept dead simple: exit now for half your FERA, or
 * wait the vest for all of it. Danger red sits on the forfeited number only. No
 * routing breakdown. Reused by the calculator and the per-grant exit confirm.
 */
export function HaircutBreakdown({ amount }: { amount: number }) {
  const h = haircut(amount);

  return (
    <div className="space-y-3">
      {/* exit now vs wait: the whole decision, side by side */}
      <div className="grid grid-cols-2 gap-3">
        <div className="rounded-lg border border-line bg-well p-4">
          <div className="overline mb-1">Exit now</div>
          <div className="font-mono tnum text-title font-semibold text-text">
            {tokenAmt(h.received, 2)}
          </div>
          <div className="text-caption text-mute">FERA, instantly</div>
        </div>
        <div className="rounded-lg border border-line bg-well p-4">
          <div className="mb-1 overline text-pos">Wait to vest</div>
          <div className="font-mono tnum text-title font-semibold text-pos">
            {tokenAmt(h.ifWaited, 2)}
          </div>
          <div className="text-caption text-mute">FERA, in full</div>
        </div>
      </div>

      {/* the one honest loss line: danger color on the number only */}
      <div className="flex items-baseline justify-between rounded-lg border border-line bg-well px-4 py-3">
        <span className="text-body-sm text-dim">You forfeit</span>
        <span className="font-mono tnum text-body font-semibold text-danger">
          {tokenAmt(h.forfeited, 2)} esFERA
        </span>
      </div>

      <p className="text-caption text-mute">
        Exit early and you keep half your FERA now. The other half is forfeited:
        partly burned, partly shared with FERA stakers.
      </p>
    </div>
  );
}
