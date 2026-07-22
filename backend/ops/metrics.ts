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
  // Audit finding (medium): keeperActive defaults false with no wired alert distinguishing "the
  // owner forgot to activate this pool" from "the keeper process is fine and there's nothing to
  // do." labels: keeper, poolId. 1 while vault-strategy's tick is currently seeing
  // PoolNotKeeperActive for that pool; the sample simply stops appearing once it activates (no
  // stale "0" left behind — see keeperInactivePoolMetrics below).
  keeperPoolNotActive: "fera_keeper_pool_not_keeper_active",
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

/**
 * Audit finding (medium): a pool the owner never (or no longer) called `setKeeperActive(id, true)`
 * for reverts `PoolNotKeeperActive` on every automated action, forever — but that's a *successful*
 * keeper tick (fail-static, nothing to submit), so it never shows up in `keeperHeartbeatMetrics`
 * above. `keepers/vaultStrategy.ts` now records every pool it saw `PoolNotKeeperActive` for in this
 * tick's heartbeat detail (`poolsNotKeeperActive: string[]`) instead of folding it into ordinary
 * no-op log noise; this turns that into a per-pool gauge so `ops/alerts.yml`'s `PoolNotKeeperActive`
 * rule can page on a pool stuck this way past its acceptable review window.
 */
export function keeperInactivePoolMetrics(heartbeatDir: string): Metric[] {
  const gauge: Metric = {
    name: METRIC.keeperPoolNotActive,
    help: "1 if the keeper is currently seeing PoolNotKeeperActive for this pool (last tick)",
    type: "gauge",
    samples: [],
  };
  let files: string[] = [];
  try {
    files = readdirSync(heartbeatDir).filter((f) => f.endsWith(".json"));
  } catch {
    return [gauge];
  }
  for (const f of files) {
    try {
      const hb = JSON.parse(readFileSync(join(heartbeatDir, f), "utf8")) as {
        keeper: string;
        poolsNotKeeperActive?: string[];
      };
      for (const poolId of hb.poolsNotKeeperActive ?? []) {
        gauge.samples.push({ labels: { keeper: hb.keeper, poolId }, value: 1 });
      }
    } catch {
      /* skip malformed */
    }
  }
  return [gauge];
}
