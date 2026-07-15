"use client";

import type { PoolDetail } from "@/lib/types";
import { Card, CardHeader } from "@/components/ui/Card";
import { Chart } from "@/components/ui/Chart";
import { LiveDot } from "@/components/ui/LiveDot";
import { feePipsToPct } from "@/lib/format";

/** Applied dynamic fee over time (lightweight-charts area series). */
export function FeeHistory({ pool }: { pool: PoolDetail }) {
  const data = pool.feeHistory.map((p) => ({
    time: p.t,
    value: +(p.feePips / 10_000).toFixed(4), // percent
  }));
  const latest = pool.feeHistory[pool.feeHistory.length - 1]?.feePips ?? pool.currentFeePips;

  return (
    <Card>
      <CardHeader
        eyebrow="Fee history"
        title="Applied dynamic fee"
        action={<LiveDot label={feePipsToPct(latest)} />}
      />
      <div className="px-3 pb-4">
        <Chart
          height={220}
          series={[
            {
              type: "area",
              data,
              color: "var(--accent)",
              topColor: "rgba(46,207,136,0.20)",
              bottomColor: "rgba(46,207,136,0.00)",
              title: "fee %",
            },
          ]}
        />
      </div>
    </Card>
  );
}
