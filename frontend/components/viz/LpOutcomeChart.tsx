"use client";

import { useId } from "react";
import { cn } from "@/lib/cn";
import { CountUp } from "./CountUp";
import {
  HollowEndpoint,
  IllustrativeChart,
  LegendChip,
  PrimaryEndpoint,
  monotonePath,
  polylineLength,
  type PlotGeometry,
} from "./IllustrativeChart";

/* ============================================================================
 * Chart A - <LpOutcomeChart>: "Same position, same path. The gap is fees."
 * (REDESIGN_PLAN.md §3 · Chart A)
 *
 * Identical LP position over the SAME modeled volatile (pump-dump) price path, so
 * impermanent loss is identical and the entire difference is fee capture. The FERA
 * regime-fee line finishes ABOVE a vanilla pool. MODELED, not a live result, and not
 * the vault versus a self-managed LP - the tag pill + caption say so.
 *
 * Datasets are seeded constants below so the shape is reproducible + identical
 * everywhere the chart is embedded.
 * ========================================================================== */

/** Cumulative LP value (%), FERA regime-fee pool. 40 pts, ends +7.5%. Modeled. */
const OUTCOME_FERA = [
  0.0, 0.3, 0.5, 0.7, 0.9, 1.1, 1.3, 1.6, 1.9, 2.4, 3.0, 3.6, 4.1, 4.5, 4.8,
  5.0, 5.1, 5.0, 4.9, 5.1, 5.5, 6.0, 6.4, 6.7, 6.9, 7.0, 6.9, 6.8, 6.9, 7.0,
  7.1, 7.2, 7.25, 7.3, 7.35, 7.4, 7.42, 7.45, 7.48, 7.5,
] as const;

/** Cumulative LP value (%), vanilla pool. Same path → same IL, ends +1.8%. Modeled. */
const OUTCOME_VANILLA = [
  0.0, 0.15, 0.28, 0.4, 0.5, 0.6, 0.68, 0.78, 0.88, 1.0, 1.15, 1.28, 1.38, 1.45,
  1.5, 1.52, 1.5, 1.42, 1.35, 1.38, 1.45, 1.52, 1.58, 1.62, 1.65, 1.66, 1.63,
  1.6, 1.62, 1.65, 1.68, 1.7, 1.72, 1.73, 1.74, 1.76, 1.77, 1.78, 1.79, 1.8,
] as const;

/** The shared modeled price path (pump then dump) - faint grey context line. */
const PRICE_PATH = [
  100, 101, 100.5, 102, 101.5, 103, 104, 106, 109, 113, 118, 124, 129, 133, 136,
  138, 137, 133, 128, 130, 134, 131, 126, 120, 115, 112, 114, 111, 109, 110,
  112, 111, 110.5, 111, 110.8, 111.2, 111, 111.3, 111.1, 111.2,
] as const;

const FERA_END = OUTCOME_FERA[OUTCOME_FERA.length - 1];
const VANILLA_END = OUTCOME_VANILLA[OUTCOME_VANILLA.length - 1];
const DELTA = Math.round((FERA_END - VANILLA_END) * 10) / 10; // +5.7 pts

const Y_MIN = 0;
const Y_MAX = 8.4; // headroom for the emphasized endpoint + label

export function LpOutcomeChart({ className }: { className?: string }) {
  const gid = useId().replace(/:/g, "");

  const renderPlot = (g: PlotGeometry) => {
    const n = OUTCOME_FERA.length;
    const tx = (i: number) => i / (n - 1);
    const tyVal = (v: number) => (v - Y_MIN) / (Y_MAX - Y_MIN);

    const feraPts = OUTCOME_FERA.map(
      (v, i) => [g.px(tx(i)), g.py(tyVal(v))] as const
    );
    const vanPts = OUTCOME_VANILLA.map(
      (v, i) => [g.px(tx(i)), g.py(tyVal(v))] as const
    );

    const pMin = Math.min(...PRICE_PATH);
    const pMax = Math.max(...PRICE_PATH);
    const pricePts = PRICE_PATH.map(
      (v, i) =>
        [g.px(tx(i)), g.py(0.08 + ((v - pMin) / (pMax - pMin)) * 0.72)] as const
    );

    const feraLine = monotonePath(feraPts);
    const vanLine = monotonePath(vanPts);
    const priceLine = monotonePath(pricePts);
    const feraArea = `${feraLine} L${g.right.toFixed(2)},${g.bottom.toFixed(
      2
    )} L${g.left.toFixed(2)},${g.bottom.toFixed(2)} Z`;

    const feraEnd = feraPts[n - 1];
    const vanEnd = vanPts[n - 1];
    const feraLen = polylineLength(feraPts);

    const draw = {
      strokeDasharray: feraLen,
      strokeDashoffset: g.visible ? 0 : feraLen,
      transition: "stroke-dashoffset 1000ms var(--ease-out)",
    } as const;

    return (
      <>
        <defs>
          <linearGradient id={`${gid}-fera`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="var(--series-fera)" stopOpacity="0.22" />
            <stop offset="100%" stopColor="var(--series-fera)" stopOpacity="0" />
          </linearGradient>
        </defs>

        {/* faint modeled price path (context) */}
        <path
          d={priceLine}
          fill="none"
          stroke="var(--series-ref)"
          strokeWidth={1}
          opacity={g.visible ? 0.14 : 0}
          vectorEffect="non-scaling-stroke"
          style={{ transition: "opacity 700ms var(--ease-out)" }}
        />
        <text
          x={g.left + 4}
          y={pricePts[0][1] - 6}
          className="font-mono"
          fontSize={10}
          fill="var(--text-mute)"
          opacity={0.7}
        >
          modeled price path
        </text>

        {/* FERA area fill */}
        <path
          d={feraArea}
          fill={`url(#${gid}-fera)`}
          opacity={g.visible ? 1 : 0}
          style={{ transition: "opacity 700ms var(--ease-out) 250ms" }}
        />

        {/* Vanilla - Cove dashed, no fill */}
        <path
          d={vanLine}
          fill="none"
          stroke="var(--series-cove)"
          strokeWidth={1.5}
          strokeDasharray="4 4"
          strokeLinecap="round"
          vectorEffect="non-scaling-stroke"
          opacity={g.visible ? 1 : 0}
          style={{ transition: "opacity 900ms var(--ease-out)" }}
        />

        {/* FERA - gold, emphasized, draws in */}
        <path
          d={feraLine}
          fill="none"
          stroke="var(--series-fera)"
          strokeWidth={2}
          strokeLinecap="round"
          strokeLinejoin="round"
          vectorEffect="non-scaling-stroke"
          style={draw}
        />

        {/* endpoints + value labels */}
        <g
          opacity={g.visible ? 1 : 0}
          style={{ transition: "opacity 500ms var(--ease-out) 850ms" }}
        >
          <HollowEndpoint x={vanEnd[0]} y={vanEnd[1]} color="var(--series-cove)" />
          <text
            x={vanEnd[0] + 9}
            y={vanEnd[1] + 4}
            className="font-mono"
            fontSize={11}
            fill="var(--series-cove)"
          >
            +{VANILLA_END.toFixed(1)}%
          </text>

          <PrimaryEndpoint
            x={feraEnd[0]}
            y={feraEnd[1]}
            color="var(--series-fera)"
            reduced={g.reduced}
          />
          <text
            x={feraEnd[0] + 9}
            y={feraEnd[1] + 4}
            className="font-mono"
            fontSize={11}
            fontWeight={600}
            fill="var(--series-fera)"
          >
            +{FERA_END.toFixed(1)}%
          </text>
        </g>
      </>
    );
  };

  return (
    <IllustrativeChart
      className={cn(className)}
      eyebrow="Fee capture"
      title={
        <>
          Same position, same path. The gap is{" "}
          <span style={{ color: "var(--accent)" }}>fees</span>.
        </>
      }
      legend={
        <>
          <LegendChip
            color="var(--series-fera)"
            label="FERA pool"
            value={`+${FERA_END.toFixed(1)}%`}
          />
          <LegendChip
            color="var(--series-cove)"
            label="Vanilla pool"
            value={`+${VANILLA_END.toFixed(1)}%`}
            dashed
          />
          <LegendChip color="var(--series-ref)" label="Price path" />
        </>
      }
      callout={
        <div>
          <div className="text-micro uppercase tracking-[0.08em] text-mute">
            Fee gap
          </div>
          <CountUp
            value={DELTA}
            suffix=" pts"
            sign
            decimals={1}
            className="text-title font-semibold text-accent"
          />
        </div>
      }
      ariaLabel={`Modeled chart: an identical LP position over the same volatile price path finishes at plus ${FERA_END} percent in a FERA pool versus plus ${VANILLA_END} percent in a vanilla pool, a gap of ${DELTA} points, entirely from fees.`}
      srTable={
        <table>
          <caption>
            Modeled cumulative LP value (%) over a synthetic pump-dump price path
          </caption>
          <thead>
            <tr>
              <th>Point</th>
              <th>FERA pool (%)</th>
              <th>Vanilla pool (%)</th>
            </tr>
          </thead>
          <tbody>
            {OUTCOME_FERA.map((v, i) => (
              <tr key={i}>
                <td>{i + 1}</td>
                <td>{v.toFixed(2)}</td>
                <td>{OUTCOME_VANILLA[i].toFixed(2)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      }
      renderPlot={renderPlot}
    />
  );
}
