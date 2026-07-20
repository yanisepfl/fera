// KEEPER 5 — MEME base+limit strategy tick (MASTER_SPEC §10, VAULT_STRATEGY_V3 §2/§6).
//
// TRIGGER: schedule (every ~30 min; the strategy is deliberately low-frequency).
//
// DOCTRINE: the VAULT owns every decision. This keeper does not try to reconstruct or judge
// band positions off-chain (that was a bug: after a limit band is deployed it can be WIDER than
// the base, so "widest band = base" misidentifies it). Instead, each tick the keeper:
//   1. syncs the on-chain out-of-range dwell clock via pokeOutOfRange() — ONLY when its state is
//      stale (base went OOR but clock unarmed, or came back IN but clock still armed), so a calm
//      pool costs zero gas. The clock must be armed for rebalanceBase's anti-whipsaw dwell gate to
//      ever be satisfiable — nothing else arms it.
//   2. ATTEMPTS rebalanceBase / skimIdle / rebalanceLimit, each SIMULATED first and sent only if
//      the simulation succeeds. The vault's own gates (NotOutOfRange, OorNotPersistent, TwapStale,
//      TwapOutOfBand, IL-budget, idle-at-target) decide whether anything happens — a not-needed
//      action reverts in simulation and is skipped at zero gas. Fail-static: a missed run just
//      holds positions.
//
// DISCOVERY: pools from the hook's PoolRegistered events (no config list). A tranche is active iff
// its FeraShare totalSupply > 0.

import { FeraVaultAbi } from "../abis/FeraVault";
import { runOnce, log, type KeeperEnv } from "./common";

const VAULT = (process.env.FERA_VAULT_ADDRESS ?? "0xa8cF82797ecBC8C5cD5F83D60e189dbDc88D959a") as `0x${string}`;
const HOOK = (process.env.FERA_HOOK_ADDRESS ?? "0x96CE193F25db9b75743332bB7C94e545f1a225C3") as `0x${string}`;
const START_BLOCK = BigInt(process.env.FERA_START_BLOCK ?? 12347590);
// Simulation identity in dry-run (no signer): the real keeper EOA, so onlyKeeper-gated eth_calls
// exercise the true path.
const KEEPER_ADDRESS = (process.env.KEEPER_ADDRESS ?? "0x7e03AebAB844aFfab9DF9c9CFB5B0C7e0d4a442E") as `0x${string}`;

const poolRegisteredEvent = {
  type: "event",
  name: "PoolRegistered",
  inputs: [
    { name: "poolId", type: "bytes32", indexed: true },
    { name: "token0", type: "address", indexed: false },
    { name: "token1", type: "address", indexed: false },
    { name: "regime", type: "uint8", indexed: false },
  ],
} as const;

// Fragments not guaranteed present in the shared ABI — declared locally.
const dwellAbi = [
  { type: "function", name: "pokeOutOfRange", stateMutability: "nonpayable", inputs: [{ name: "id", type: "bytes32" }, { name: "t", type: "uint8" }], outputs: [{ name: "oor", type: "bool" }] },
  { type: "function", name: "outOfRangeSince", stateMutability: "view", inputs: [{ name: "id", type: "bytes32" }, { name: "t", type: "uint8" }], outputs: [{ type: "uint64" }] },
] as const;

const erc20SupplyAbi = [
  { type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

/** simulate as the keeper; send only when the simulation succeeds (zero wasted gas). */
async function simulateThenSend(
  env: KeeperEnv,
  poolId: `0x${string}`,
  functionName: "skimIdle" | "rebalanceLimit" | "rebalanceBase",
  args: readonly unknown[],
): Promise<boolean> {
  try {
    const { request } = await env.publicClient.simulateContract({
      address: VAULT,
      abi: FeraVaultAbi,
      functionName,
      args: args as never,
      account: env.account ?? KEEPER_ADDRESS,
    });
    if (env.dryRun || !env.walletClient) {
      log("vault-strategy", "info", `DRY RUN — would send ${functionName}`, { poolId });
      return false;
    }
    const hash = await env.walletClient.writeContract(request);
    const rcpt = await env.publicClient.waitForTransactionReceipt({ hash });
    log("vault-strategy", rcpt.status === "success" ? "info" : "warn", `${functionName} ${rcpt.status}`, { poolId, hash });
    return rcpt.status === "success";
  } catch (e) {
    // Simulation revert = the vault says "not needed / not yet" (NotOutOfRange, OorNotPersistent,
    // TwapStale, idle at target…). Expected — log at debug and skip.
    log("vault-strategy", "info", `${functionName} skipped`, {
      poolId,
      reason: String((e as Error).message ?? e).match(/Error: (\w+)/)?.[1] ?? "reverted",
    });
    return false;
  }
}

/** Keep the on-chain dwell clock in sync with reality; send a poke ONLY on a state transition. */
async function syncDwellClock(env: KeeperEnv, poolId: `0x${string}`, t: number): Promise<void> {
  let oorNow: boolean;
  try {
    const sim = await env.publicClient.simulateContract({
      address: VAULT, abi: dwellAbi, functionName: "pokeOutOfRange", args: [poolId, t],
      account: env.account ?? KEEPER_ADDRESS,
    });
    oorNow = sim.result as boolean;
  } catch {
    return; // can't read → skip this tick (fail-static)
  }
  const since = (await env.publicClient
    .readContract({ address: VAULT, abi: dwellAbi, functionName: "outOfRangeSince", args: [poolId, t] })
    .catch(() => 0n)) as bigint;
  const armed = since !== 0n;
  if (oorNow === armed) return; // clock already correct — no tx
  log("vault-strategy", "info", `dwell clock ${oorNow ? "ARM" : "reset"}`, { poolId, tranche: t });
  if (env.dryRun || !env.walletClient) {
    log("vault-strategy", "info", "DRY RUN — would poke", { poolId });
    return;
  }
  const { request } = await env.publicClient.simulateContract({
    address: VAULT, abi: dwellAbi, functionName: "pokeOutOfRange", args: [poolId, t],
    account: env.account,
  });
  const hash = await env.walletClient.writeContract(request);
  await env.publicClient.waitForTransactionReceipt({ hash });
  log("vault-strategy", "info", "poked", { poolId, hash });
}

export async function tick(env: KeeperEnv): Promise<void> {
  const pools = await env.publicClient.getLogs({
    address: HOOK, event: poolRegisteredEvent, fromBlock: START_BLOCK, toBlock: "latest",
  });
  // Idle-skim + limit-(re)deploy are LOW-URGENCY and gas-heavy across many pools — at bootstrap
  // TVL the per-tick churn (100+/day) outran the fees it captured and drained the keeper. Throttle
  // them to a ~4h cadence off the block clock (stateless — GitHub Actions runs are ephemeral); the
  // base recenter + dwell-clock still run EVERY tick because those are the position-holding safety
  // actions. When real TVL makes frequent limit redeploys worth their gas, widen this.
  const { timestamp } = await env.publicClient.getBlock();
  // Run the gas-heavy skim/limit maintenance at most ONCE PER DAY (the hourly tick at ~03:00 UTC).
  // That's ~48x fewer runs than the original every-tick behaviour that drained the keeper. At
  // bootstrap TVL a limit band earns cents/day — nowhere near its per-redeploy gas — so daily is
  // already generous; set KEEPER_SKIMLIMIT_HOUR=-1 to pause it entirely, or widen at real TVL.
  const skimHour = Number(process.env.KEEPER_SKIMLIMIT_HOUR ?? 3);
  const doSkimLimit = skimHour >= 0 && Math.floor(Number(timestamp % 86400n) / 3600) === skimHour;
  log("vault-strategy", "info", `discovered ${pools.length} pools; skim/limit ${doSkimLimit ? "ON" : "throttled"} this tick`);

  for (const p of pools) {
    const poolId = (p.args as { poolId: `0x${string}` }).poolId;
    for (const t of [0, 1] as const) {
      // active tranche only (tranche 1 exists on-chain but may be unseeded)
      let share: `0x${string}`;
      try {
        share = (await env.publicClient.readContract({
          address: VAULT, abi: FeraVaultAbi, functionName: "shareToken", args: [poolId, t],
        })) as `0x${string}`;
      } catch { continue; }
      const supply = await env.publicClient
        .readContract({ address: share, abi: erc20SupplyAbi, functionName: "totalSupply" })
        .catch(() => 0n);
      if (supply === 0n) continue;

      await syncDwellClock(env, poolId, t);                            // 1. dwell clock — every tick
      await simulateThenSend(env, poolId, "rebalanceBase", [poolId, t, true]); // 2. recenter base if due — every tick
      if (doSkimLimit) {                                                       // 3+4. throttled ~4h
        await simulateThenSend(env, poolId, "skimIdle", [poolId, t]);
        await simulateThenSend(env, poolId, "rebalanceLimit", [poolId, t]);
      }
    }
  }
}

runOnce("vault-strategy", tick).then((code) => process.exit(code));
