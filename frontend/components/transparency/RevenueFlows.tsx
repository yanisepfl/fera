"use client";

import { useRevenue } from "@/lib/hooks/useApi";
import { Card, CardHeader } from "@/components/ui/Card";
import { Skeleton } from "@/components/ui/Skeleton";
import { usdCompact, usd } from "@/lib/format";

/**
 * RevenueDistributor split, from GET /transparency/revenue (§8). Every inflow is split
 * exactly 50/25/25 (stakers / treasury / ops) with no rounding dust escaping (INV-10).
 */
export function RevenueFlows() {
  const { data, isLoading } = useRevenue();

  if (isLoading || !data)
    return <Skeleton className="h-72 w-full rounded-lg" />;

  const total = data.toStakers + data.toTreasury + data.toOps;
  const flows = [
    {
      label: "Stakers",
      pct: 50,
      amount: data.toStakers,
      color: "var(--pos)",
      note: "Real revenue share, paid to sFERA stakers",
    },
    {
      label: "Treasury",
      pct: 25,
      amount: data.toTreasury,
      color: "var(--rwa)",
      note: "48h timelocked sink",
    },
    {
      label: "Ops",
      pct: 25,
      amount: data.toOps,
      color: "var(--text-mute)",
      note: "Operations",
    },
  ];

  return (
    <Card>
      <CardHeader
        eyebrow="Revenue"
        title="Where revenue goes · 50 / 25 / 25"
        action={
          <span className="font-mono tnum text-body-sm text-dim">
            {usdCompact(total)} · this epoch
          </span>
        }
      />
      <div className="px-5 pb-5 space-y-5">
        {/* single 50/25/25 bar */}
        <div className="flex h-3 overflow-hidden rounded-full">
          {flows.map((f) => (
            <div
              key={f.label}
              style={{ width: `${f.pct}%`, background: f.color }}
              title={`${f.label} ${f.pct}%`}
            />
          ))}
        </div>

        <div className="grid grid-cols-3 gap-3">
          {flows.map((f) => (
            <div
              key={f.label}
              className="rounded-lg border border-line bg-well p-3"
            >
              <div className="flex items-center gap-1.5">
                <span
                  className="h-2 w-2 rounded-full"
                  style={{ background: f.color }}
                />
                <span className="overline">{f.label}</span>
              </div>
              <div className="mt-1 font-mono tnum text-title font-semibold text-text">
                {f.pct}%
              </div>
              <div className="font-mono tnum text-caption text-mute">
                {usdCompact(f.amount)}
              </div>
              <div className="mt-1 text-caption text-mute">{f.note}</div>
            </div>
          ))}
        </div>

        {/* by-token breakdown */}
        <div>
          <div className="overline mb-2">By token (real fees collected)</div>
          <div className="space-y-1.5">
            {data.byToken.map((t) => {
              const byTotal = data.byToken.reduce((s, x) => s + x.amount, 0) || 1;
              const w = (t.amount / byTotal) * 100;
              return (
                <div key={t.token.symbol} className="flex items-center gap-3">
                  <span className="w-16 shrink-0 text-body-sm text-dim">
                    {t.token.symbol}
                  </span>
                  <div className="h-2 flex-1 overflow-hidden rounded-full bg-surface">
                    <div
                      className="h-full rounded-full bg-line-strong"
                      style={{ width: `${w.toFixed(1)}%` }}
                    />
                  </div>
                  <span className="w-24 shrink-0 text-right font-mono tnum text-body-sm text-text">
                    {usd(t.amount, 0)}
                  </span>
                </div>
              );
            })}
          </div>
        </div>

        <p className="text-caption text-mute">
          Split is immutable (5000 / 2500 / 2500 bps) and pull-based; no dust escapes
          accounting (INV-10). Revenue is real fee tokens, not FERA.
        </p>
      </div>
    </Card>
  );
}
