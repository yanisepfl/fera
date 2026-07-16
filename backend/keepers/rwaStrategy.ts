// KEEPER 2/4 — RWA regime-appropriate base defense (MASTER_SPEC §10, VAULT_STRATEGY_V3 §5.1).
//
// TRIGGER: per (RWA pool, tranche), each tick. RWA prices MEAN-REVERT to the underlying real stock
// (unlike a memecoin), so the correct posture is the OPPOSITE of MEME and is chosen by MARKET STATE:
//   * IN-HOURS  (market open AND NOT in an event window):
//       FeraVault.rebalanceRwaOracle(poolId, tranche) — re-anchor the base band TOWARD the Chainlink
//       oracle when the pool price has drifted past hysteresis (TWAP-confirmed). Providing liquidity
//       at the true price is correct because RWA reverts to it. Swap-free (band<->reserve, zero IL).
//   * OFF-HOURS (market closed OR event-window/earnings flagged):
//       FeraVault.defendRwaOffHours(poolId, tranche) — WIDEN the base band + PARTIAL-WITHDRAW a
//       fraction into idle reserve, so weekend drift + a Monday-open gap can't realise IL into a
//       tight, stale-priced band. Swap-free, value-conserving.
// Both are per-(pool,tranche) and KEEPER-ONLY; the keeper just TRIGGERS — the Vault re-enforces every
// bound on-chain and reverts if unmet, so a buggy/adversarial keeper can't force a bad rebalance and a
// missing keeper just holds (fail-static, §10 / INV-12).
//
// MARKET-STATE GATE MIRROR (contracts VaultRwa.sol): the branch we pick here is the exact inverse the
// Vault enforces, so we never submit a tx it rejects on state:
//   rebalanceRwaOracle reverts MarketClosed unless (isMarketOpen && !isEventWindow)
//   defendRwaOffHours  reverts MarketOpen   unless (!isMarketOpen || isEventWindow)
//
// PT-6 — MIN_RECENTER_INTERVAL GUARD (Open Decisions PT-6, ACCEPTED): RWA tick-boundary griefing is
// UNBOUNDED without a minimum interval between base moves (model bleeds ~3.84%/day of TVL). The guard
// is keeper-scoped AND on-chain-enforced:
//   * ON-CHAIN (authoritative): FeraVault gates BOTH base actions on the dedicated slow base-recenter
//     clock — it reverts RebalanceTooSoon if `block.timestamp - lastBaseRecenterTs < min` (hardcoded
//     bound, INV-12). This keeper does NOT get to override it.
//   * OFF-CHAIN (this keeper, courtesy pre-check): we skip proposing within MIN_RECENTER_INTERVAL of
//     the last observed base action so we don't waste gas on a tx the Vault would revert. If our local
//     value drifts from the on-chain constant, the on-chain bound still wins.
//
// MEV (§10, D-6): base-move timing is RANDOMIZED within the trigger window (jitter) so the exact block
// is unpredictable. Robinhood Chain is FCFS with no priority ordering (D-6) so this + a private RPC is
// sufficient, not over-built.

import { FeraVaultAbi } from "../abis/FeraVault";
import { runOnce, log, isUnset, jitterMs, type KeeperEnv } from "./common";
import type { Hex } from "../pipeline/types";

// Local mirror of the ON-CHAIN constant. The chain value is authoritative (INV-12). PT-6
// FROZEN: PARAMS.md#RWA_MIN_RECENTER_INTERVAL_SEC = 14400 (4h) — bounds tick-boundary griefing
// at 0.48%/day worst case. TODO(deploy): read from the Vault instead of env.
const MIN_RECENTER_INTERVAL_S = Number(process.env.KEEPER_MIN_RECENTER_INTERVAL_S ?? 14400);
// Hysteresis: minimum |pool−oracle| deviation (bps) before we even consider an in-hours recenter.
// On-chain re-checked. TODO(spec-freeze): PARAMS.md#rwa_recenter_hysteresis_bps.
const HYSTERESIS_BPS = Number(process.env.KEEPER_RECENTER_HYSTERESIS_BPS ?? 50);
const STRATEGY_WINDOW_MS = Number(process.env.KEEPER_STRATEGY_WINDOW_MS ?? 30_000);

// RWA base-limit pools have two INV-15-segregated tranches: 0 = Steady, 1 = Active
// (createBaseLimitPool sets trancheCount = 2). The base defense is per-tranche.
const RWA_TRANCHES = [0, 1] as const;

interface PoolState {
  poolId: Hex;
  lastRecenterTs: number; // last observed base action (StrategyAction recenter/widen); 0 if never
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

/**
 * Pure guard for the IN-HOURS oracle recenter (on-chain re-verifies all of this — INV-6 + PT-6).
 * `marketOpen` here means IN-HOURS = (isMarketOpen AND NOT event-window), matching the Vault's
 * rebalanceRwaOracle gate.
 */
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

/** Pure guard for the OFF-HOURS defense: only the shared base-recenter min-interval applies (the
 *  defense is triggered by market state, not oracle deviation). On-chain clock is authoritative. */
export function mayDefend(params: { nowTs: number; lastRecenterTs: number }): { ok: boolean; reason: string } {
  if (params.nowTs - params.lastRecenterTs < MIN_RECENTER_INTERVAL_S)
    return { ok: false, reason: "min-recenter-interval (PT-6)" };
  return { ok: true, reason: "defend-eligible" };
}

async function tick(env: KeeperEnv): Promise<void> {
  const vault = process.env.FERA_VAULT_ADDRESS;
  if (isUnset(vault)) {
    log("rwa-strategy", "warn", "FERA_VAULT_ADDRESS unset — skipping (fail-static)");
    return;
  }
  const nowTs = Math.floor(Date.now() / 1000);
  for (const st of rwaPools()) {
    // Market state is per-pool. IN-HOURS = market open AND not an event window (exact mirror of the
    // Vault's on-chain gate) — picks which base defense is legal this tick.
    const [marketOpen, eventWindow] = (await Promise.all([
      env.publicClient.readContract({
        address: vault as `0x${string}`,
        abi: FeraVaultAbi,
        functionName: "isMarketOpen",
        args: [st.poolId],
      }),
      env.publicClient.readContract({
        address: vault as `0x${string}`,
        abi: FeraVaultAbi,
        functionName: "isEventWindow",
        args: [st.poolId],
      }),
    ])) as [boolean, boolean];
    const inHours = marketOpen && !eventWindow;

    // deviationBps: |poolPrice − oraclePrice| in bps — computed from oracle + pool TWAP reads. Only
    // used for the in-hours recenter. TODO(deploy): read oracle (Chainlink adapter) + pool TWAP;
    // placeholder 0 keeps the in-hours recenter fail-static (never proposes) until the reads are
    // wired. On-chain INV-6 is the real gate regardless.
    const deviationBps = 0;

    for (const tranche of RWA_TRANCHES) {
      if (inHours) {
        const guard = mayRecenter({ marketOpen: inHours, deviationBps, nowTs, lastRecenterTs: st.lastRecenterTs });
        if (!guard.ok) {
          log("rwa-strategy", "info", "skip in-hours recenter", { poolId: st.poolId, tranche, reason: guard.reason });
          continue;
        }
        await new Promise((r) => setTimeout(r, jitterMs(STRATEGY_WINDOW_MS))); // MEV jitter
        if (env.dryRun || !env.walletClient || !env.account) {
          log("rwa-strategy", "info", "DRY-RUN would rebalanceRwaOracle", { poolId: st.poolId, tranche });
          continue;
        }
        const hash = await env.walletClient.writeContract({
          chain: null,
          account: env.account,
          address: vault as `0x${string}`,
          abi: FeraVaultAbi,
          functionName: "rebalanceRwaOracle",
          args: [st.poolId, tranche],
        });
        log("rwa-strategy", "info", "rebalanceRwaOracle submitted (on-chain re-verifies INV-6 + PT-6)", {
          poolId: st.poolId,
          tranche,
          hash,
        });
      } else {
        const guard = mayDefend({ nowTs, lastRecenterTs: st.lastRecenterTs });
        if (!guard.ok) {
          log("rwa-strategy", "info", "skip off-hours defend", { poolId: st.poolId, tranche, reason: guard.reason });
          continue;
        }
        await new Promise((r) => setTimeout(r, jitterMs(STRATEGY_WINDOW_MS))); // MEV jitter
        if (env.dryRun || !env.walletClient || !env.account) {
          log("rwa-strategy", "info", "DRY-RUN would defendRwaOffHours", { poolId: st.poolId, tranche });
          continue;
        }
        const hash = await env.walletClient.writeContract({
          chain: null,
          account: env.account,
          address: vault as `0x${string}`,
          abi: FeraVaultAbi,
          functionName: "defendRwaOffHours",
          args: [st.poolId, tranche],
        });
        log("rwa-strategy", "info", "defendRwaOffHours submitted (on-chain re-verifies market-state + PT-6)", {
          poolId: st.poolId,
          tranche,
          hash,
        });
      }
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runOnce("rwa-strategy", tick).then((code) => process.exit(code));
}

export { tick as rwaStrategyTick };
