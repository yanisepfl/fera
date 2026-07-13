// Prometheus metrics — text exposition format, dependency-free (no prom-client needed for a
// stub). Two producers feed these:
//   * the indexer / a sidecar exposes indexer-lag + epoch gauges,
//   * the keepers write heartbeat files (keepers/common.ts) which this exporter turns into
//     keeper-miss gauges,
//   * ops/reconcile.ts writes the fee-accounting drift gauge.
//
// Serve `renderMetrics()` at GET /metrics (Prometheus scrape target — see ops/prometheus.yml).
// Alert rules live in ops/alerts.yml (indexer lag, keeper misses, oracle staleness, reconcile
// drift). This is a STUB: field names + semantics are frozen here so the alert rules and Grafana
// dashboard bind to stable metric names; wiring to the live indexer is a deploy task.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export type Labels = Record<string, string>;

export interface Metric {
  name: string;
  help: string;
  type: "gauge" | "counter";
  samples: { labels?: Labels; value: number }[];
}

function fmtLabels(l?: Labels): string {
  if (!l || Object.keys(l).length === 0) return "";
  const inner = Object.entries(l)
    .map(([k, v]) => `${k}="${String(v).replace(/"/g, '\\"')}"`)
    .join(",");
  return `{${inner}}`;
}

export function renderMetrics(metrics: Metric[]): string {
  const lines: string[] = [];
  for (const m of metrics) {
    lines.push(`# HELP ${m.name} ${m.help}`);
    lines.push(`# TYPE ${m.name} ${m.type}`);
    for (const s of m.samples) lines.push(`${m.name}${fmtLabels(s.labels)} ${s.value}`);
  }
  return lines.join("\n") + "\n";
}

// ---- Canonical FERA metric names (bind alert rules + dashboards to these) -------------------
export const METRIC = {
  indexerLagSeconds: "fera_indexer_lag_seconds", // now - lastIndexedBlockTimestamp
  indexerHeadBlock: "fera_indexer_head_block",
  keeperLastSuccessTs: "fera_keeper_last_success_timestamp", // labels: keeper
  keeperOk: "fera_keeper_ok", // 1/0, labels: keeper
  epochLastPosted: "fera_epoch_last_posted", // last epochId with a Distributor root
  oracleSecondsSinceUpdate: "fera_oracle_seconds_since_update", // labels: symbol
  reconcileFeeDriftBps: "fera_reconcile_fee_drift_bps", // labels: poolId; |indexer-onchain|/onchain
  reconcilePerfFeeViolations: "fera_reconcile_perf_fee_violations_total", // INV-3 breaches
} as const;

/** Build the keeper-heartbeat gauges from the files keepers/common.ts writes. */
export function keeperHeartbeatMetrics(heartbeatDir: string): Metric[] {
  const lastSuccess: Metric = { name: METRIC.keeperLastSuccessTs, help: "Unix ts of last successful keeper tick", type: "gauge", samples: [] };
  const ok: Metric = { name: METRIC.keeperOk, help: "1 if last keeper tick succeeded else 0", type: "gauge", samples: [] };
  let files: string[] = [];
  try {
    files = readdirSync(heartbeatDir).filter((f) => f.endsWith(".json"));
  } catch {
    return [lastSuccess, ok];
  }
  for (const f of files) {
    try {
      const hb = JSON.parse(readFileSync(join(heartbeatDir, f), "utf8")) as { keeper: string; ok: boolean; ts: number };
      lastSuccess.samples.push({ labels: { keeper: hb.keeper }, value: hb.ts });
      ok.samples.push({ labels: { keeper: hb.keeper }, value: hb.ok ? 1 : 0 });
    } catch {
      /* skip malformed */
    }
  }
  return [lastSuccess, ok];
}
