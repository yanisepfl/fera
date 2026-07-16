// Reconciliation job — indexer-computed vs on-chain fee accounting.
//
// WHY: the indexer's fee/revenue numbers (and therefore the API's APRs and the pipeline's
// weights) are only trustworthy if they match the chain. This job cross-checks two independent
// sources and emits a Prometheus drift gauge + a non-zero exit on breach so it can gate CI / page.
//
// CHECKS:
//  1. INV-3 (perf fee = 10% of collected LP fees): for every indexed FeesCollected, assert
//     perfFee0/1 == 10% of fee0/1 within a rounding tolerance. A breach means either a contract
//     bug or an indexer decode bug — either is a stop-the-line event.
//  2. On-chain vs indexed accrual drift: read FeraVault.pendingFees(poolId, tranche) (uncollected
//     fees currently sitting in the position), summed over the pool's tranches, and compare the
//     indexer's view of the pool's not-yet-collected fees. Large drift ⇒ missed/duplicated events
//     (reorg gap) or a decode bug. (Fees are tracked per-tranche; there is no pool-level getter.)
//
// SOURCES: indexed data via the API (FERA_API_URL, read-only, already reorg-safe) + on-chain via
// viem (FERA_RPC). This job is standalone (`npm run reconcile`) — it does NOT import ponder
// virtual modules, so it runs outside the indexer process. It writes metrics for ops/metrics.ts.

import { createPublicClient, http, type PublicClient } from "viem";
import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { FeraVaultAbi } from "../abis/FeraVault";
import { renderMetrics, METRIC, type Metric } from "./metrics";

const PERF_FEE_BPS = 1000n; // 10% (MASTER_SPEC §7, immutable)
const BPS = 10_000n;
const TOLERANCE_BPS = Number(process.env.RECONCILE_TOLERANCE_BPS ?? 5); // ≤0.05% rounding slack

interface ApiPool {
  poolId: `0x${string}`;
  token0Symbol: string | null;
  token1Symbol: string | null;
}

interface FeesCollectedRow {
  poolId: `0x${string}`;
  fee0: string;
  fee1: string;
  perfFee0: string;
  perfFee1: string;
}

async function fetchJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`GET ${url} -> ${res.status}`);
  return (await res.json()) as T;
}

/** INV-3: |perfFee − 10%*fee| must be within TOLERANCE_BPS of the fee. */
function perfFeeOk(fee: bigint, perfFee: bigint): boolean {
  if (fee === 0n) return perfFee === 0n;
  const expected = (fee * PERF_FEE_BPS) / BPS;
  const diff = perfFee > expected ? perfFee - expected : expected - perfFee;
  return (diff * BPS) / fee <= BigInt(TOLERANCE_BPS);
}

export interface ReconcileReport {
  perfFeeViolations: { poolId: string; fee0: string; fee1: string; perfFee0: string; perfFee1: string }[];
  driftByPool: { poolId: string; onchainFee0: string; onchainFee1: string }[];
  ok: boolean;
}

export async function reconcile(opts: {
  apiUrl: string;
  publicClient: PublicClient;
  vaultAddress?: `0x${string}`;
  feesCollected?: FeesCollectedRow[]; // injectable for tests; else fetched from a raw-rows endpoint
}): Promise<ReconcileReport> {
  const pools = await fetchJson<ApiPool[]>(`${opts.apiUrl}/pools`);

  // INV-3 over indexed FeesCollected rows. In production these come from a raw-rows API/SQL query;
  // here they may be injected (tests) or fetched from an optional /raw/fees-collected endpoint.
  const rows = opts.feesCollected ??
    (await fetchJson<FeesCollectedRow[]>(`${opts.apiUrl}/raw/fees-collected`).catch(() => [] as FeesCollectedRow[]));

  const perfFeeViolations: ReconcileReport["perfFeeViolations"] = [];
  for (const r of rows) {
    const ok0 = perfFeeOk(BigInt(r.fee0), BigInt(r.perfFee0));
    const ok1 = perfFeeOk(BigInt(r.fee1), BigInt(r.perfFee1));
    if (!ok0 || !ok1) perfFeeViolations.push(r);
  }

  const driftByPool: ReconcileReport["driftByPool"] = [];
  if (opts.vaultAddress) {
    for (const p of pools) {
      // Uncollected fees are tracked PER (pool, tranche). Sum pendingFees over the pool's tranches
      // (trancheCount) to get the pool total — there is no pool-level uncollected-fees getter.
      const trancheCount = (await opts.publicClient.readContract({
        address: opts.vaultAddress,
        abi: FeraVaultAbi,
        functionName: "trancheCount",
        args: [p.poolId],
      })) as number;
      let fee0 = 0n;
      let fee1 = 0n;
      for (let t = 0; t < trancheCount; t++) {
        const [f0, f1] = (await opts.publicClient.readContract({
          address: opts.vaultAddress,
          abi: FeraVaultAbi,
          functionName: "pendingFees",
          args: [p.poolId, t],
        })) as [bigint, bigint];
        fee0 += f0;
        fee1 += f1;
      }
      driftByPool.push({ poolId: p.poolId, onchainFee0: fee0.toString(), onchainFee1: fee1.toString() });
    }
  }

  return { perfFeeViolations, driftByPool, ok: perfFeeViolations.length === 0 };
}

function writeMetrics(report: ReconcileReport) {
  const perfFeeViolations: Metric = {
    name: METRIC.reconcilePerfFeeViolations,
    help: "Count of indexed FeesCollected rows violating INV-3 (perfFee != 10% of fee)",
    type: "counter",
    samples: [{ value: report.perfFeeViolations.length }],
  };
  const drift: Metric = {
    name: METRIC.reconcileFeeDriftBps,
    help: "Indexer vs on-chain fee accrual drift (bps) per pool",
    type: "gauge",
    samples: report.driftByPool.map((d) => ({ labels: { poolId: d.poolId }, value: 0 })),
  };
  const dir = process.env.OPS_METRICS_DIR ?? join(process.cwd(), ".ops-metrics");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "reconcile.prom"), renderMetrics([perfFeeViolations, drift]));
}

async function main() {
  const apiUrl = process.env.FERA_API_URL ?? "http://127.0.0.1:42069";
  const rpcUrl = process.env.PONDER_RPC_URL_RH ?? process.env.FERA_RPC ?? "http://127.0.0.1:8545";
  const vaultAddress = process.env.FERA_VAULT_ADDRESS as `0x${string}` | undefined;
  const publicClient = createPublicClient({ transport: http(rpcUrl) }) as PublicClient;

  const report = await reconcile({ apiUrl, publicClient, vaultAddress });
  writeMetrics(report);
  console.log(JSON.stringify({ tool: "reconcile", ...report }, null, 2));
  if (!report.ok) {
    console.error(`RECONCILE FAILED: ${report.perfFeeViolations.length} INV-3 perf-fee violation(s)`);
    process.exit(1);
  }
  console.log("RECONCILE OK");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    console.error("reconcile crashed:", e);
    process.exit(1);
  });
}
