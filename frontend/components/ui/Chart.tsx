"use client";

import { useEffect, useRef } from "react";

export interface ChartSeries {
  type: "area" | "line";
  data: { time: number; value: number }[];
  color: string;
  topColor?: string;
  bottomColor?: string;
  lineWidth?: 1 | 2 | 3;
  lineStyle?: 0 | 1 | 2 | 3; // solid, dotted, dashed, large-dashed
  title?: string;
}

export interface PriceMarker {
  price: number;
  color: string;
  title: string;
  lineStyle?: 0 | 1 | 2 | 3;
}

/**
 * Thin wrapper over lightweight-charts (v4). Dynamically imported inside an effect
 * so the library never runs during SSR / `next build`. Styled to the FERA dark
 * theme (greyscale grid + axis, accent reserved for the primary/live series).
 */
export function Chart({
  series,
  priceLines = [],
  height = 240,
  className,
}: {
  series: ChartSeries[];
  priceLines?: PriceMarker[];
  height?: number;
  className?: string;
}) {
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let chart: any;
    let disposed = false;
    let ro: ResizeObserver | undefined;

    // lightweight-charts parses colors itself and can't read CSS custom properties —
    // resolve "var(--token)" to its computed literal value before handing colors over.
    const resolveColor = (c: string): string => {
      const m = /^var\((--[^)]+)\)$/.exec(c.trim());
      if (!m) return c;
      const v = getComputedStyle(document.documentElement).getPropertyValue(m[1]).trim();
      return v || "#888888";
    };

    (async () => {
      const lc: any = await import("lightweight-charts");
      if (disposed || !ref.current) return;
      chart = lc.createChart(ref.current, {
        height,
        layout: {
          background: { type: lc.ColorType.Solid, color: "transparent" },
          textColor: "#616f68", // --text-mute
          fontFamily:
            "var(--font-mono), ui-monospace, SFMono-Regular, Menlo, monospace",
          fontSize: 11,
          attributionLogo: false,
        },
        grid: {
          vertLines: { color: "#18211d" }, // --chart-grid
          horzLines: { color: "#18211d" },
        },
        rightPriceScale: { borderColor: "#1f2a25" }, // --line
        timeScale: { borderColor: "#1f2a25", timeVisible: true, secondsVisible: false },
        crosshair: {
          vertLine: { color: "#2b3a33", labelBackgroundColor: "#18211d" }, // --line-strong / --ink-750
          horzLine: { color: "#2b3a33", labelBackgroundColor: "#18211d" },
        },
        handleScale: false,
        handleScroll: false,
      });

      for (const s of series) {
        const opts: any = {
          lineWidth: s.lineWidth ?? 2,
          lineStyle: s.lineStyle ?? 0,
          priceLineVisible: false,
          lastValueVisible: false,
          title: s.title,
        };
        const color = resolveColor(s.color);
        let ser: any;
        if (s.type === "area") {
          ser = chart.addAreaSeries({
            ...opts,
            lineColor: color,
            topColor: s.topColor ? resolveColor(s.topColor) : color + "40",
            bottomColor: s.bottomColor ? resolveColor(s.bottomColor) : color + "00",
          });
        } else {
          ser = chart.addLineSeries({ ...opts, color });
        }
        ser.setData(s.data);
      }

      // draw horizontal reference lines (e.g. Chainlink oracle price) on first series
      if (priceLines.length && series.length) {
        // create a hidden anchor series to hang price lines on
        const anchor = chart.addLineSeries({ visible: false });
        anchor.setData(series[0].data);
        for (const pl of priceLines) {
          anchor.createPriceLine({
            price: pl.price,
            color: resolveColor(pl.color),
            lineWidth: 1,
            lineStyle: pl.lineStyle ?? 2,
            axisLabelVisible: true,
            title: pl.title,
          });
        }
      }

      chart.timeScale().fitContent();

      ro = new ResizeObserver((entries) => {
        for (const e of entries) chart?.applyOptions({ width: e.contentRect.width });
      });
      ro.observe(ref.current);
    })();

    return () => {
      disposed = true;
      ro?.disconnect();
      chart?.remove();
    };
  }, [series, priceLines, height]);

  return <div ref={ref} className={className} style={{ height }} />;
}
