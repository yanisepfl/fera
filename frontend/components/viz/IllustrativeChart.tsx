"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { cn } from "@/lib/cn";

/* ============================================================================
 * IllustrativeChart - the shared frame for FERA's two SVG illustrative charts
 * (REDESIGN_PLAN.md §3). Build once, both charts use it.
 *
 * Self-contained: pure SVG, NO chart library. Renders the Cove-glow card, the
 * mandatory Illustrative / Modeled tag pill (so these can never be mistaken for
 * live data), a horizontal-only grid + stronger baseline, an inline legend, an
 * honest caption, and an accessible role="img" label. The plot itself is drawn by
 * each chart via the `renderPlot` render prop, which receives pixel geometry.
 * ========================================================================== */

/* ----------------------------------------------------------------- geometry -- */

/** Inner plot padding. Right pad leaves room for the mono endpoint value labels. */
export const CHART_PAD = { top: 18, right: 54, bottom: 30, left: 14 } as const;

export interface PlotGeometry {
  /** Full measured svg width / height in px. */
  width: number;
  height: number;
  /** Inner plot rect edges in px. */
  left: number;
  right: number;
  top: number;
  bottom: number;
  innerWidth: number;
  innerHeight: number;
  /** Map a normalized point (tx,ty in 0..1, ty=0 bottom) to pixels. */
  px: (tx: number) => number;
  py: (ty: number) => number;
  /** True once the card has scrolled into view (drives entrance animation). */
  visible: boolean;
  /** True under prefers-reduced-motion (skip line-draw / fades). */
  reduced: boolean;
}

/** Monotone-cubic (Fritsch–Carlson) interpolation - d3 curveMonotoneX equivalent,
 *  implemented inline so lines are smooth with no overshoot and no dependency. */
export function monotonePath(points: readonly (readonly [number, number])[]): string {
  const n = points.length;
  if (n === 0) return "";
  if (n === 1) return `M${points[0][0]},${points[0][1]}`;
  if (n === 2)
    return `M${points[0][0]},${points[0][1]}L${points[1][0]},${points[1][1]}`;

  const xs = points.map((p) => p[0]);
  const ys = points.map((p) => p[1]);
  const dx: number[] = [];
  const slope: number[] = [];
  for (let i = 0; i < n - 1; i++) {
    dx[i] = xs[i + 1] - xs[i] || 1e-6;
    slope[i] = (ys[i + 1] - ys[i]) / dx[i];
  }
  const m: number[] = new Array(n);
  m[0] = slope[0];
  m[n - 1] = slope[n - 2];
  for (let i = 1; i < n - 1; i++) {
    if (slope[i - 1] * slope[i] <= 0) {
      m[i] = 0;
    } else {
      const w1 = 2 * dx[i] + dx[i - 1];
      const w2 = dx[i] + 2 * dx[i - 1];
      m[i] = (w1 + w2) / (w1 / slope[i - 1] + w2 / slope[i]);
    }
  }

  let d = `M${xs[0].toFixed(2)},${ys[0].toFixed(2)}`;
  for (let i = 0; i < n - 1; i++) {
    const c1x = xs[i] + dx[i] / 3;
    const c1y = ys[i] + (m[i] * dx[i]) / 3;
    const c2x = xs[i + 1] - dx[i] / 3;
    const c2y = ys[i + 1] - (m[i + 1] * dx[i]) / 3;
    d += `C${c1x.toFixed(2)},${c1y.toFixed(2)} ${c2x.toFixed(2)},${c2y.toFixed(
      2
    )} ${xs[i + 1].toFixed(2)},${ys[i + 1].toFixed(2)}`;
  }
  return d;
}

/** Approximate polyline length (for the stroke-dashoffset draw-in entrance). */
export function polylineLength(
  points: readonly (readonly [number, number])[]
): number {
  let len = 0;
  for (let i = 1; i < points.length; i++) {
    len += Math.hypot(
      points[i][0] - points[i - 1][0],
      points[i][1] - points[i - 1][1]
    );
  }
  // monotone cubic is a touch longer than the polyline; pad so the draw fully covers.
  return len * 1.15;
}

/* ------------------------------------------------------------------- hooks --- */

/** Measure a container's width with a ResizeObserver (same approach as Sparkline). */
function useMeasuredWidth<T extends HTMLElement>() {
  const ref = useRef<T | null>(null);
  const [width, setWidth] = useState(0);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      for (const e of entries) setWidth(e.contentRect.width);
    });
    ro.observe(el);
    setWidth(el.clientWidth);
    return () => ro.disconnect();
  }, []);
  return [ref, width] as const;
}

/* --------------------------------------------------------- shared subparts --- */

/** The mandatory honesty tag - always visible, top-right of every illustrative chart. */
export function TagPill({ kind }: { kind: "Illustrative" | "Modeled" }) {
  return (
    <span className="inline-flex items-center gap-1.5 rounded-full border border-line bg-surface px-2.5 py-1 text-micro uppercase tracking-[0.08em] text-mute">
      <span
        className="h-1.5 w-1.5 rounded-full"
        style={{ background: "var(--accent2)" }}
      />
      {kind}
    </span>
  );
}

/** Inline legend chip: colored dot + label + optional mono value. */
export function LegendChip({
  color,
  label,
  value,
  dashed = false,
}: {
  color: string;
  label: string;
  value?: string;
  dashed?: boolean;
}) {
  return (
    <span className="inline-flex items-center gap-1.5">
      {dashed ? (
        <span
          className="inline-block h-0 w-3.5 border-t-2 border-dashed"
          style={{ borderColor: color }}
        />
      ) : (
        <span
          className="inline-block h-2 w-2 rounded-full"
          style={{ background: color }}
        />
      )}
      <span className="text-caption text-dim">{label}</span>
      {value ? (
        <span className="font-mono text-caption tabular-nums" style={{ color }}>
          {value}
        </span>
      ) : null}
    </span>
  );
}

/** Emphasized primary endpoint: filled dot + soft pulsing halo (reduced-motion safe). */
export function PrimaryEndpoint({
  x,
  y,
  color,
  reduced,
}: {
  x: number;
  y: number;
  color: string;
  reduced: boolean;
}) {
  return (
    <g>
      {!reduced && (
        <circle
          cx={x}
          cy={y}
          r={8}
          fill={color}
          opacity={0.18}
          className="animate-pulse-live"
          style={{ transformOrigin: `${x}px ${y}px` }}
        />
      )}
      <circle cx={x} cy={y} r={4} fill={color} />
      <circle cx={x} cy={y} r={4} fill="none" stroke="var(--ink-875)" strokeWidth={1.5} />
    </g>
  );
}

/** Hollow secondary endpoint. */
export function HollowEndpoint({
  x,
  y,
  color,
}: {
  x: number;
  y: number;
  color: string;
}) {
  return (
    <circle
      cx={x}
      cy={y}
      r={3.5}
      fill="var(--ink-875)"
      stroke={color}
      strokeWidth={1.5}
    />
  );
}

/* ------------------------------------------------------------------- frame --- */

export function IllustrativeChart({
  eyebrow,
  title,
  tag,
  legend,
  callout,
  caption,
  ariaLabel,
  srTable,
  renderPlot,
  className,
}: {
  eyebrow: string;
  title: React.ReactNode;
  tag: "Illustrative" | "Modeled";
  legend?: React.ReactNode;
  /** Optional prominent figure (e.g. the +5.7 pts delta callout). */
  callout?: React.ReactNode;
  caption: React.ReactNode;
  ariaLabel: string;
  /** Optional visually-hidden data table for screen readers. */
  srTable?: React.ReactNode;
  renderPlot: (g: PlotGeometry) => React.ReactNode;
  className?: string;
}) {
  const [ref, width] = useMeasuredWidth<HTMLDivElement>();
  const [visible, setVisible] = useState(false);
  const cardRef = useRef<HTMLDivElement | null>(null);
  const [reduced, setReduced] = useState(false);

  useEffect(() => {
    const mq = window.matchMedia?.("(prefers-reduced-motion: reduce)");
    const apply = () => setReduced(!!mq?.matches);
    apply();
    mq?.addEventListener?.("change", apply);
    return () => mq?.removeEventListener?.("change", apply);
  }, []);

  useEffect(() => {
    const el = cardRef.current;
    if (!el) return;
    if (reduced || typeof IntersectionObserver === "undefined") {
      setVisible(true);
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting) {
            setVisible(true);
            io.disconnect();
          }
        }
      },
      { threshold: 0.25 }
    );
    io.observe(el);
    return () => io.disconnect();
  }, [reduced]);

  const height = width && width < 480 ? 220 : 280;

  const geo = useMemo<PlotGeometry | null>(() => {
    if (!width) return null;
    const left = CHART_PAD.left;
    const right = width - CHART_PAD.right;
    const top = CHART_PAD.top;
    const bottom = height - CHART_PAD.bottom;
    const innerWidth = Math.max(1, right - left);
    const innerHeight = Math.max(1, bottom - top);
    return {
      width,
      height,
      left,
      right,
      top,
      bottom,
      innerWidth,
      innerHeight,
      px: (tx: number) => left + tx * innerWidth,
      py: (ty: number) => bottom - ty * innerHeight,
      visible,
      reduced,
    };
  }, [width, height, visible, reduced]);

  // 4 horizontal gridlines + a stronger baseline.
  const gridFractions = [0, 0.25, 0.5, 0.75];

  return (
    <div
      ref={cardRef}
      className={cn(
        "card-glow card-glow--cove rounded-lg border border-line bg-card p-5 shadow-card md:p-6",
        className
      )}
    >
      {/* header */}
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="overline overline-cove mb-1.5">{eyebrow}</div>
          <h3 className="text-heading font-semibold tracking-tight text-text">
            {title}
          </h3>
        </div>
        <div className="flex shrink-0 flex-col items-end gap-2">
          <TagPill kind={tag} />
          {callout ? <div className="text-right">{callout}</div> : null}
        </div>
      </div>

      {/* legend */}
      {legend ? (
        <div className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1.5">
          {legend}
        </div>
      ) : null}

      {/* plot */}
      <div ref={ref} className="mt-4" style={{ height }}>
        {geo ? (
          <svg
            width={width}
            height={height}
            viewBox={`0 0 ${width} ${height}`}
            role="img"
            aria-label={ariaLabel}
            className="block overflow-visible"
          >
            {/* horizontal grid */}
            {gridFractions.map((f) => {
              const y = geo.py(f);
              return (
                <line
                  key={f}
                  x1={geo.left}
                  x2={geo.right}
                  y1={y}
                  y2={y}
                  stroke="var(--chart-grid)"
                  strokeWidth={1}
                />
              );
            })}
            {/* stronger baseline */}
            <line
              x1={geo.left}
              x2={geo.right}
              y1={geo.bottom}
              y2={geo.bottom}
              stroke="var(--line)"
              strokeWidth={1}
            />
            {renderPlot(geo)}
          </svg>
        ) : null}
      </div>

      {/* caption */}
      <p className="mt-3 text-body-sm text-mute">{caption}</p>

      {srTable ? <div className="sr-only">{srTable}</div> : null}
    </div>
  );
}
