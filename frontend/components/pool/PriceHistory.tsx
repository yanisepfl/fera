"use client";

import { useMemo } from "react";
import type { PoolId } from "@/lib/types";
import { useCandles } from "@/lib/hooks/useApi";
import { Card, CardHeader } from "@/components/ui/Card";
import { Chart, type ChartSeries } from "@/components/ui/Chart";
import { LiveDot } from "@/components/ui/LiveDot";
import { usdPrice } from "@/lib/format";

/**
 * REAL market price history for the pool's underlying venue (pre-launch live mode).
 * Data is GET /pools/:poolId/ohlcv — actual Robinhood Chain trades via the backend's
 * GeckoTerminal feed. This is MARKET data, not vault performance; it renders nothing
 * rather than something invented when the series is unavailable.
 */
export function PriceHistory({ poolId, symbol }: { poolId: PoolId; symbol: string }) {
  const { data: candles } = useCandles(poolId);

  const series = useMemo<ChartSeries[]>(() => {
    const data = (candles ?? []).map((c) => ({ time: c.t, value: c.c }));
    return [
      {
        type: "area",
        data,
        color: "var(--accent2)",
        topColor: "rgba(47,224,138,0.18)",
        bottomColor: "rgba(47,224,138,0.00)",
        title: `${symbol} $`,
      },
    ];
  }, [candles, symbol]);

  if (!candles?.length) return null;
  const last = candles[candles.length - 1];

  return (
    <Card>
      <CardHeader
        eyebrow="Market price"
        title={`${symbol} · last 7 days`}
        action={<LiveDot label={usdPrice(last.c)} color="var(--accent2)" />}
      />
      <div className="px-3 pb-2">
        <Chart height={220} series={series} />
      </div>
      <p className="px-5 pb-4 text-caption text-mute">
        Real trades on Robinhood Chain (hourly closes, via GeckoTerminal). Market data —
        not vault performance.
      </p>
    </Card>
  );
}
