"use client";

import { haircut } from "@/lib/vesting";
import { tokenAmt } from "@/lib/format";
import { cn } from "@/lib/cn";

/**
 * The forfeiture breakdown, styled so the loss is IMPOSSIBLE TO MISS:
 * loud danger color, explicit "you forfeit" line, and the 1/3-1/3-1/3 routing.
 * Reused by the standalone calculator and the per-grant instant-exit confirm.
 */
export function HaircutBreakdown({
  amount,
  compact = false,
}: {
  amount: number;
  compact?: boolean;
}) {
  const h = haircut(amount);
  const pctLost = amount > 0 ? (h.forfeited / amount) * 100 : 0;

  return (
    <div className="space-y-3">
      {/* the loud loss banner */}
      <div className="rounded-lg border border-danger-line bg-danger-wash p-4 shadow-glow-danger">
        <div className="flex items-center justify-between">
          <span className="text-micro font-semibold uppercase tracking-[0.1em] text-danger">
            ⚠ You permanently forfeit
          </span>
          <span className="font-mono tnum text-body-sm text-danger">
            −{pctLost.toFixed(0)}%
          </span>
        </div>
        <div className="mt-1 flex items-baseline gap-2">
          <span className="font-mono tnum text-display-l font-bold text-danger">
            {tokenAmt(h.forfeited, 2)}
          </span>
          <span className="text-body text-danger/80">esFERA gone</span>
        </div>
        <p className="mt-1 text-caption text-danger/80">
          Instant exit burns half your esFERA. This cannot be undone.
        </p>
      </div>

      {/* receive vs wait */}
      <div className="grid grid-cols-2 gap-3">
        <div className="rounded-lg border border-line bg-well p-3">
          <div className="overline mb-1">You receive now</div>
          <div className="font-mono tnum text-title font-semibold text-text">
            {tokenAmt(h.received, 2)}
          </div>
          <div className="text-caption text-mute">FERA, instantly</div>
        </div>
        <div className="rounded-lg border border-line bg-well p-3">
          <div className="overline mb-1">If you wait the vest</div>
          <div className="font-mono tnum text-title font-semibold text-pos">
            {tokenAmt(h.ifWaited, 2)}
          </div>
          <div className="text-caption text-mute">FERA, over ~6mo (1:1)</div>
        </div>
      </div>

      {/* forfeiture routing, INV-9 */}
      {!compact ? (
        <div className="rounded-lg border border-line bg-card p-3">
          <div className="overline mb-2">
            Where the forfeited {tokenAmt(h.forfeited, 2)} goes (1/3 each · INV-9)
          </div>
          <div className="grid grid-cols-3 gap-2 text-center">
            <RoutePill label="Burned" v={h.toBurn} />
            <RoutePill label="To stakers" v={h.toStakers} />
            <RoutePill label="To revenue" v={h.toRevenue} />
          </div>
        </div>
      ) : null}
    </div>
  );
}

function RoutePill({ label, v }: { label: string; v: number }) {
  return (
    <div className={cn("rounded-md bg-surface px-2 py-2")}>
      <div className="font-mono tnum text-body font-semibold text-text">
        {tokenAmt(v, 2)}
      </div>
      <div className="text-micro uppercase tracking-wide text-mute">{label}</div>
    </div>
  );
}
