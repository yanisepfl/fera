// KEEPER 2/4 — RWA strategy execution (MASTER_SPEC §10).
//
// TRIGGER: oracle moved past hysteresis AND underlying market open.
// ACTION: FeraVault.executeStrategy(poolId, kind) — recenter (1) / widen (2) / partialWithdraw
// (3), off a candidate the keeper proposes; the Vault decides the actual band on-chain.
//
// ON-CHAIN VERIFICATION BOUNDS (§10 + INV-6): "Vault re-checks oracle + hysteresis + TWAP
// on-chain; reverts if unmet (INV-6)." So this keeper is a best-effort PROPOSER. Every guard it
// evaluates off-chain is RE-ENFORCED on-chain — a recenter reverts unless (oracle moved past
// hysteresis) AND (underlying market open) AND (pool-price TWAP within sanity band of oracle). A
// buggy/adversarial keeper cannot force a bad rebalance; a missing keeper just holds (fail-static).
//
// PT-6 — MIN_RECENTER_INTERVAL GUARD (Open Decisions PT-6, ACCEPTED): RWA tick-boundary griefing
// is UNBOUNDED without a minimum interval between recenters (model bleeds ~3.84%/day of TVL). The
// guard is keeper-scoped AND on-chain-enforced:
//   * ON-CHAIN (authoritative): FeraVault MUST reject a recenter if
//     `block.timestamp - lastRecenterTs(poolId) < MIN_RECENTER_INTERVAL` (hardcoded bound,
//     INV-12). Value frozen by Mechanism in PARAMS.md#min_recenter_interval. This keeper does NOT
//     get to override it.
//   * OFF-CHAIN (this keeper, courtesy pre-check): we skip proposing a recenter within
//     MIN_RECENTER_INTERVAL of the last observed StrategyAction(kind=1) so we don't waste gas on a
//     tx the Vault will revert. If our local value drifts from the on-chain constant, the on-chain
//     bound still wins.
//
// MEV (§10, D-6): recenter timing is RANDOMIZED within the trigger window (jitter) so the exact
// block is unpredictable. Robinhood Chain is FCFS with no priority ordering (D-6) so this + a
// private RPC is sufficient, not over-built.

import { FeraVaultAbi } from "../abis/FeraVault";
import { runOnce, log, isUnset, jitterMs, type KeeperEnv } from "./common";
import type { Hex } from "../pipeline/types";

// Local mirror of the ON-CHAIN constant. The chain value is authoritative (INV-12). PT-6
// FROZEN: PARAMS.md#RWA_MIN_RECENTER_INTERVAL_SEC = 14400 (4h) — bounds tick-boundary griefing
// at 0.48%/day worst case. TODO(deploy): read from the Vault instead of env.
const MIN_RECENTER_INTERVAL_S = Number(process.env.KEEPER_MIN_RECENTER_INTERVAL_S ?? 14400);
// Hysteresis: minimum |pool−oracle| deviation (bps) before we even consider a recenter. On-chain
// re-checked (INV-6). TODO(spec-freeze): PARAMS.md#rwa_recenter_hysteresis_bps.
const HYSTERESIS_BPS = Number(process.env.KEEPER_RECENTER_HYSTERESIS_BPS ?? 50);
const STRATEGY_WINDOW_MS = Number(process.env.KEEPER_STRATEGY_WINDOW_MS ?? 30_000);

const KIND_RECENTER = 1;

interface PoolState {
  poolId: Hex;
  lastRecenterTs: number; // from indexed StrategyAction(kind=1); 0 if never
}

function rwaPools(): PoolState[] {
  const raw = process.env.KEEPER_RWA_POOLS;
  if (!raw) return [];
  return raw
    .split(",")
    .map((s) => s.trim() as Hex)
    .filter((s) => s.length === 66)
    .map((poolId) => ({ poolId, lastRecenterTs: 0 }));
}

/** Pure guard: may we PROPOSE a recenter? (on-chain re-verifies all of this — INV-6 + PT-6). */
export function mayRecenter(params: {
  marketOpen: boolean;
  deviationBps: number;
  nowTs: number;
  lastRecenterTs: number;
}): { ok: boolean; reason: string } {
  if (!params.marketOpen) return { ok: false, reason: "market-closed" };
  if (params.deviationBps < HYSTERESIS_BPS) return { ok: false, reason: "within-hysteresis" };
  if (params.nowTs - params.lastRecenterTs < MIN_RECENTER_INTERVAL_S)
    return { ok: false, reason: "min-recenter-interval (PT-6)" };
  return { ok: true, reason: "recenter-eligible" };
}

async function tick(env: KeeperEnv): Promise<void> {
  const vault = process.env.FERA_VAULT_ADDRESS;
  if (isUnset(vault)) {
    log("rwa-strategy", "warn", "FERA_VAULT_ADDRESS unset — skipping (fail-static)");
    return;
  }
  const nowTs = Math.floor(Date.now() / 1000);
  for (const st of rwaPools()) {
    const marketOpen = (await env.publicClient.readContract({
      address: vault as `0x${string}`,
      abi: FeraVaultAbi,
      functionName: "isMarketOpen",
      args: [st.poolId],
    })) as boolean;

    // deviationBps: |poolPrice − oraclePrice| in bps — computed from oracle + pool TWAP reads.
    // TODO(deploy): read oracle (Chainlink adapter) + pool TWAP; placeholder 0 keeps us fail-static
    // (never proposes) until the reads are wired. On-chain INV-6 is the real gate regardless.
    const deviationBps = 0;

    const guard = mayRecenter({ marketOpen, deviationBps, nowTs, lastRecenterTs: st.lastRecenterTs });
    if (!guard.ok) {
      log("rwa-strategy", "info", "skip recenter", { poolId: st.poolId, reason: guard.reason });
      continue;
    }
    // MEV: randomize submission time within the window.
    await new Promise((r) => setTimeout(r, jitterMs(STRATEGY_WINDOW_MS)));

    if (env.dryRun || !env.walletClient || !env.account) {
      log("rwa-strategy", "info", "DRY-RUN would executeStrategy", { poolId: st.poolId, kind: KIND_RECENTER });
      continue;
    }
    const hash = await env.walletClient.writeContract({
      chain: null,
      account: env.account,
      address: vault as `0x${string}`,
      abi: FeraVaultAbi,
      functionName: "executeStrategy",
      args: [st.poolId, KIND_RECENTER],
    });
    log("rwa-strategy", "info", "executeStrategy submitted (on-chain re-verifies INV-6 + PT-6)", {
      poolId: st.poolId,
      kind: KIND_RECENTER,
      hash,
    });
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runOnce("rwa-strategy", tick).then((code) => process.exit(code));
}

export { tick as rwaStrategyTick };
