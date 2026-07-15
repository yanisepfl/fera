"use client";

import type { PoolDetail } from "@/lib/types";
import { Card, CardHeader } from "@/components/ui/Card";
import { STRATEGY_KIND_META } from "@/lib/regime";
import { usd, shortHex } from "@/lib/format";

function ago(t: number) {
  const s = Math.floor(Date.now() / 1000 - t);
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

/** Every strategy action, oracle-anchored + justification-hashed (INV-6 auditability). */
export function StrategyLog({ pool }: { pool: PoolDetail }) {
  const hasDrip = pool.strategyLog.some((e) => e.kind === 5);
  return (
    <Card>
      <CardHeader eyebrow="Strategy log" title="Every action, on the record" />
      <div className="px-5 pb-5">
        {pool.regime === "MEME" ? (
          <p className="mb-4 text-caption text-mute">
            <span className="text-pos">Fee redeployments</span> just move your earnings
            to follow the price; <span className="text-accent">deposit</span> changes are
            rare and safety-checked.{" "}
            {hasDrip
              ? "The fees follow the price without disturbing your original deposit."
              : ""}
          </p>
        ) : null}
        <ol className="relative space-y-4 border-l border-line pl-5">
          {pool.strategyLog.map((e, i) => {
            const meta = STRATEGY_KIND_META[e.kind];
            const dot = meta.principal ? "var(--accent)" : "var(--pos)";
            return (
              <li key={i} className="relative">
                <span
                  className="absolute -left-[23px] top-1 h-2.5 w-2.5 rounded-full border-2 border-canvas"
                  style={{ background: dot }}
                />
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="flex items-center gap-2 text-body font-medium text-text">
                    {meta.label}
                    <span
                      className="rounded-full px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide"
                      style={{
                        color: dot,
                        background: meta.principal
                          ? "var(--accent-wash)"
                          : "var(--pos-wash)",
                      }}
                    >
                      {meta.principal ? "deposit" : "fees"}
                    </span>
                  </span>
                  <span className="text-caption text-mute">{ago(e.t)}</span>
                </div>
                <p className="text-body-sm text-dim">{meta.note}</p>
                <div className="mt-1 flex flex-wrap gap-x-4 gap-y-0.5 text-caption text-mute font-mono tnum">
                  <span>
                    ticks [{e.tickLower}, {e.tickUpper}]
                  </span>
                  {e.oraclePrice ? <span>oracle {usd(e.oraclePrice)}</span> : null}
                  <span>proof {shortHex(e.justificationHash)}</span>
                  {e.txHash ? <span className="text-accent-dim">tx {shortHex(e.txHash)}</span> : null}
                </div>
              </li>
            );
          })}
        </ol>
      </div>
    </Card>
  );
}
