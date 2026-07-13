"use client";

import { useId } from "react";
import { cn } from "@/lib/cn";
import {
  IllustrativeChart,
  LegendChip,
  PrimaryEndpoint,
  monotonePath,
  polylineLength,
  type PlotGeometry,
} from "./IllustrativeChart";

/* ============================================================================
 * Chart B - <FeeResponseChart>: "The fee rises when it needs to."
 * (REDESIGN_PLAN.md §3 · Chart B)
 *
 * The LP fee rises with realized volatility (cushioning LP loss in the worst
 * periods) and stays low in calm markets (to pull volume). ILLUSTRATIVE shape - 
 * the exact curve is set on-chain per pool. Cove volatility area is the driver;
 * the gold line is the fee tracking it above a floor.
 * ========================================================================== */

/** Realized volatility (modeled, arbitrary scale) across calm → storm → calm. */
const VOL = [
  8, 8, 9, 9, 10, 11, 12, 14, 18, 24, 32, 42, 52, 61, 68, 73, 76, 78, 77, 74,
  69, 62, 54, 45, 37, 30, 24, 19, 16, 14, 12, 11, 10, 10, 9, 9, 9, 10, 10, 10,
] as const;

/** LP fee (%), tracks realized volatility above the on-chain floor. */
const FEE = [
  0.34, 0.34, 0.34, 0.35, 0.35, 0.36, 0.38, 0.41, 0.46, 0.54, 0.66, 0.82, 0.99,
  1.15, 1.3, 1.42, 1.5, 1.55, 1.54, 1.49, 1.4, 1.28, 1.15, 1.01, 0.88, 0.76,
  0.65, 0.56, 0.49, 0.44, 0.4, 0.38, 0.36, 0.35, 0.35, 0.34, 0.34, 0.35, 0.35,
  0.36,
] as const;

const FEE_FLOOR = 0.34; // MEME fee floor, plain
const FEE_END = FEE[FEE.length - 1];

const VOL_MAX = 90;
const FEE_MAX = 1.8;

// Zone boundaries (indices) for the volatile band.
const VOL_START = 10;
const VOL_END = 27;

export function FeeResponseChart({ className }: { className?: string }) {
  const gid = useId().replace(/:/g, "");

  const renderPlot = (g: PlotGeometry) => {
    const n = FEE.length;
    const tx = (i: number) => i / (n - 1);
    const volTy = (v: number) => (v / VOL_MAX) * 0.9 + 0.03;
    const feeTy = (v: number) => (v / FEE_MAX) * 0.9 + 0.03;

    const volPts = VOL.map((v, i) => [g.px(tx(i)), g.py(volTy(v))] as const);
    const feePts = FEE.map((v, i) => [g.px(tx(i)), g.py(feeTy(v))] as const);

    const volLine = monotonePath(volPts);
    const feeLine = monotonePath(feePts);
    const volArea = `${volLine} L${g.right.toFixed(2)},${g.bottom.toFixed(
      2
    )} L${g.left.toFixed(2)},${g.bottom.toFixed(2)} Z`;

    const feeEnd = feePts[n - 1];
    const feeLen = polylineLength(feePts);
    const floorY = g.py(feeTy(FEE_FLOOR));

    const zoneX1 = g.px(tx(VOL_START));
    const zoneX2 = g.px(tx(VOL_END));

    const draw = {
      strokeDasharray: feeLen,
      strokeDashoffset: g.visible ? 0 : feeLen,
      transition: "stroke-dashoffset 1000ms var(--ease-out)",
    } as const;

    const fade = (delay = 0, dur = 700) =>
      ({
        opacity: g.visible ? 1 : 0,
        transition: `opacity ${dur}ms var(--ease-out) ${delay}ms`,
      }) as const;

    return (
      <>
        <defs>
          <linearGradient id={`${gid}-vol`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="var(--series-cove)" stopOpacity="0.18" />
            <stop offset="100%" stopColor="var(--series-cove)" stopOpacity="0" />
          </linearGradient>
        </defs>

        {/* volatile-zone wash */}
        <rect
          x={zoneX1}
          y={g.top}
          width={Math.max(0, zoneX2 - zoneX1)}
          height={g.bottom - g.top}
          fill="var(--accent2-wash)"
          style={fade(0, 600)}
        />

        {/* x-axis zone labels */}
        <g style={fade(200, 600)}>
          {[
            { t: "Calm", cx: (g.left + zoneX1) / 2 },
            { t: "Volatile", cx: (zoneX1 + zoneX2) / 2 },
            { t: "Calm", cx: (zoneX2 + g.right) / 2 },
          ].map((z, i) => (
            <text
              key={i}
              x={z.cx}
              y={g.bottom + 18}
              textAnchor="middle"
              className="font-mono"
              fontSize={11}
              letterSpacing="0.06em"
              fill="var(--text-mute)"
            >
              {z.t}
            </text>
          ))}
        </g>

        {/* volatility area (driver / context) */}
        <path d={volArea} fill={`url(#${gid}-vol)`} style={fade(250)} />
        <path
          d={volLine}
          fill="none"
          stroke="var(--series-cove)"
          strokeWidth={1.5}
          strokeLinecap="round"
          vectorEffect="non-scaling-stroke"
          style={fade(150, 900)}
        />

        {/* fee floor - faint dashed */}
        <line
          x1={g.left}
          x2={g.right}
          y1={floorY}
          y2={floorY}
          stroke="var(--accent-dim)"
          strokeWidth={1}
          strokeDasharray="3 4"
          opacity={g.visible ? 0.9 : 0}
          style={{ transition: "opacity 600ms var(--ease-out)" }}
        />
        <text
          x={g.left + 4}
          y={floorY - 5}
          className="font-mono"
          fontSize={10}
          fill="var(--accent-dim)"
          style={fade(300)}
        >
          fee floor {FEE_FLOOR.toFixed(2)}%
        </text>

        {/* fee line - gold, draws in */}
        <path
          d={feeLine}
          fill="none"
          stroke="var(--series-fera)"
          strokeWidth={2}
          strokeLinecap="round"
          strokeLinejoin="round"
          vectorEffect="non-scaling-stroke"
          style={draw}
        />

        {/* annotations */}
        <g style={fade(850, 500)}>
          <text
            x={g.px(0.46)}
            y={g.py(0.24)}
            textAnchor="middle"
            className="font-sans"
            fontSize={11}
            fill="var(--text-dim)"
          >
            cushions LPs here
          </text>
          <text
            x={g.px(0.82)}
            y={g.py(0.5)}
            textAnchor="middle"
            className="font-sans"
            fontSize={11}
            fill="var(--text-mute)"
          >
            low fee pulls volume
          </text>
        </g>

        {/* fee endpoint - pulsing gold + current value */}
        <g style={fade(900, 500)}>
          <PrimaryEndpoint
            x={feeEnd[0]}
            y={feeEnd[1]}
            color="var(--series-fera)"
            reduced={g.reduced}
          />
          <text
            x={feeEnd[0] + 9}
            y={feeEnd[1] + 4}
            className="font-mono"
            fontSize={11}
            fontWeight={600}
            fill="var(--series-fera)"
          >
            {FEE_END.toFixed(2)}%
          </text>
        </g>
      </>
    );
  };

  return (
    <IllustrativeChart
      className={cn(className)}
      eyebrow="Regime fee, illustrative"
      title={
        <>
          The fee rises when{" "}
          <span style={{ color: "var(--accent2)" }}>volatility</span> does.
        </>
      }
      tag="Illustrative"
      legend={
        <>
          <LegendChip color="var(--series-fera)" label="LP fee" />
          <LegendChip color="var(--series-cove)" label="Realized volatility" />
        </>
      }
      caption="Illustrative shape of the regime fee. It rises with realized volatility to cushion LPs when flow is most toxic, and stays low in calm markets to pull volume. The exact curve is set on-chain per pool."
      ariaLabel="Illustrative chart: the LP fee tracks realized volatility, rising from a floor of 0.34 percent through a volatile period and returning toward the floor as the market calms."
      srTable={
        <table>
          <caption>
            Illustrative LP fee versus realized volatility across a calm → storm →
            calm window
          </caption>
          <thead>
            <tr>
              <th>Point</th>
              <th>Realized volatility</th>
              <th>LP fee (%)</th>
            </tr>
          </thead>
          <tbody>
            {FEE.map((v, i) => (
              <tr key={i}>
                <td>{i + 1}</td>
                <td>{VOL[i]}</td>
                <td>{v.toFixed(2)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      }
      renderPlot={renderPlot}
    />
  );
}
