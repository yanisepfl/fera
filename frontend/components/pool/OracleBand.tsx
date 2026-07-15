"use client";

import type { PoolDetail } from "@/lib/types";
import { Card, CardHeader } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { MARKET_HOURS_META } from "@/lib/regime";
import { usd, signedPct } from "@/lib/format";
import { cn } from "@/lib/cn";

/**
 * RWA oracle-anchored band: live pool price vs Chainlink oracle, the recenter band,
 * and the market-hours state that governs widen/recenter behavior (SHARED_CONTEXT §2/3).
 */
export function OracleBand({ pool }: { pool: PoolDetail }) {
  const mh = pool.marketHoursState
    ? MARKET_HOURS_META[pool.marketHoursState]
    : null;
  const drift = pool.oraclePrice
    ? (pool.poolPrice - pool.oraclePrice) / pool.oraclePrice
    : 0;

  const lo = pool.band.priceLower ?? pool.oraclePrice * 0.98;
  const hi = pool.band.priceUpper ?? pool.oraclePrice * 1.02;
  const span = hi - lo || 1;
  const posPct = (v: number) => Math.max(0, Math.min(100, ((v - lo) / span) * 100));

  return (
    <Card>
      <CardHeader
        eyebrow="Stock strategy"
        title="Range anchored to a reference price"
        action={
          mh ? (
            <Badge color={mh.color} wash="var(--ink-800)" dot>
              {mh.label}
            </Badge>
          ) : null
        }
      />
      <div className="px-5 pb-5 space-y-5">
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">
          <div>
            <div className="overline mb-1">Reference price</div>
            <div className="font-mono tnum text-title font-semibold text-rwa">
              {usd(pool.oraclePrice)}
            </div>
          </div>
          <div>
            <div className="overline mb-1">Pool price</div>
            <div className="font-mono tnum text-title font-semibold text-text">
              {usd(pool.poolPrice)}
            </div>
          </div>
          <div>
            <div className="overline mb-1">Drift vs reference</div>
            <div
              className={cn(
                "font-mono tnum text-title font-semibold",
                Math.abs(drift) < 0.001 ? "text-text" : drift > 0 ? "text-pos" : "text-neg"
              )}
            >
              {signedPct(drift)}
            </div>
          </div>
        </div>

        {/* band visual */}
        <div>
          <div className="relative h-16 rounded-lg border border-line bg-well">
            {/* band fill */}
            <div className="absolute inset-y-2 left-3 right-3">
              <div className="relative h-full rounded-md bg-rwa-wash">
                {/* oracle marker */}
                <Marker pct={posPct(pool.oraclePrice)} color="var(--regime-rwa)" label="Reference" />
                {/* pool marker */}
                <Marker pct={posPct(pool.poolPrice)} color="var(--text)" label="Pool" top />
              </div>
            </div>
          </div>
          <div className="mt-1.5 flex justify-between text-caption text-mute font-mono tnum">
            <span>{usd(lo)}</span>
            <span>band</span>
            <span>{usd(hi)}</span>
          </div>
        </div>

        <p className="text-caption text-mute">
          {mh?.open
            ? "Market open: the range stays tight and only re-centers when the reference price moves enough to matter."
            : "Off-hours: the range widened and the fee scales with how far the pool price has drifted from the reference. That weekend drift becomes recurring income for you, instead of a loss."}
        </p>
      </div>
    </Card>
  );
}

function Marker({
  pct,
  color,
  label,
  top,
}: {
  pct: number;
  color: string;
  label: string;
  top?: boolean;
}) {
  return (
    <div
      className="absolute top-0 h-full"
      style={{ left: `${pct}%`, transform: "translateX(-50%)" }}
    >
      <div className="mx-auto h-full w-0.5" style={{ background: color }} />
      <span
        className={cn(
          "absolute left-1/2 -translate-x-1/2 whitespace-nowrap text-[10px] font-semibold",
          top ? "-top-1.5" : "-bottom-1.5"
        )}
        style={{ color }}
      >
        {label}
      </span>
    </div>
  );
}
