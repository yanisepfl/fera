"use client";

import { useEmissions } from "@/lib/hooks/useApi";
import { Card, CardHeader } from "@/components/ui/Card";
import { Chart, type ChartSeries } from "@/components/ui/Chart";
import { Skeleton } from "@/components/ui/Skeleton";
import { InfoTip } from "@/components/ui/InfoTip";
import { num } from "@/lib/format";

// Concrete token values (from globals.css) — lightweight-charts renders on canvas
// and cannot resolve CSS custom properties, so we pass resolved hex/rgba here.
const C = {
  accent: "#e7b84b", // emitted (primary)
  rwa: "#5aa9e6", // β × revenue bound
  grid3: "#9a9aa4", // logistic cap (supply schedule)
};

// Weekly epochs on a fixed anchor so the time axis is deterministic (SSR-safe).
const EPOCH0_TS = Date.UTC(2026, 0, 5) / 1000; // Mon 2026-01-05
const WEEK = 7 * 86400;

/**
 * The tokenomics-pitch chart: emissions vs BOTH bounds.
 *   - grey dashed  = logistic S-curve cap(t)  (the supply schedule ceiling)
 *   - azure dashed = β × revenueValuedInFera   (the revenue bound)
 *   - gold area    = emitted = min(cap, β·rev) (what actually mints)
 * Whenever azure sits below grey, issuance is revenue-gated: emissions can never
 * exceed revenue (INV-7). Early epochs are gated by revenue, not by the cap.
 */
export function EmissionsChart() {
  const { data, isLoading } = useEmissions();

  if (isLoading || !data)
    return <Skeleton className="h-80 w-full rounded-lg" />;

  const at = (epochId: number) => EPOCH0_TS + epochId * WEEK;

  const series: ChartSeries[] = [
    {
      type: "line",
      data: data.series.map((p) => ({ time: at(p.epochId), value: p.cap })),
      color: C.grid3,
      lineWidth: 1,
      lineStyle: 2, // dashed
      title: "cap(t)",
    },
    {
      type: "line",
      data: data.series.map((p) => ({ time: at(p.epochId), value: p.revenueBound })),
      color: C.rwa,
      lineWidth: 1,
      lineStyle: 2,
      title: "β × revenue",
    },
    {
      type: "area",
      data: data.series.map((p) => ({ time: at(p.epochId), value: p.emitted })),
      color: C.accent,
      topColor: "rgba(231,184,75,0.22)",
      bottomColor: "rgba(231,184,75,0.00)",
      lineWidth: 2,
      title: "emitted",
    },
  ];

  const last = data.series[data.series.length - 1];

  return (
    <Card>
      <CardHeader
        eyebrow="Emissions"
        title="Emissions vs cap vs β-bound"
        action={
          <InfoTip text="emitted = min(cap(t), β × revenueValuedInFera). β = 0.8. The gold area can only ever touch the LOWER of the two dashed lines — issuance never exceeds revenue (INV-7)." />
        }
      />
      <div className="px-3 pb-2">
        <Chart series={series} height={280} />
      </div>
      <div className="flex flex-wrap items-center gap-x-5 gap-y-2 px-5 pb-4">
        <Legend color={C.accent} label="Emitted = min(cap, β·rev)" solid />
        <Legend color={C.grid3} label="Logistic cap(t) — supply schedule" />
        <Legend color={C.rwa} label="β × revenue bound (β = 0.8)" />
      </div>
      <div className="border-t border-line px-5 py-4">
        <p className="text-body-sm text-dim">
          <span className="font-medium text-text">This is the whole tokenomics
          promise:</span>{" "}
          esFERA is a dividend of real activity, not a subsidy. Emissions are pinned
          to the lower of a fixed supply schedule and 0.8× the revenue the protocol
          actually earned. Latest epoch #{last.epochId}: cap{" "}
          <span className="font-mono tnum text-text">{num(last.cap)}</span>, β-bound{" "}
          <span className="font-mono tnum text-rwa">{num(last.revenueBound)}</span> →
          emitted{" "}
          <span className="font-mono tnum text-accent">{num(last.emitted)}</span> FERA.
        </p>
      </div>
    </Card>
  );
}

function Legend({
  color,
  label,
  solid,
}: {
  color: string;
  label: string;
  solid?: boolean;
}) {
  return (
    <span className="inline-flex items-center gap-2 text-caption text-dim">
      <span
        className="inline-block h-0.5 w-5 rounded-full"
        style={{
          background: solid
            ? color
            : `repeating-linear-gradient(90deg, ${color} 0 4px, transparent 4px 7px)`,
        }}
      />
      {label}
    </span>
  );
}
