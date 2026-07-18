// KEEPER 5 — MEME base+limit strategy tick (MASTER_SPEC §10, VAULT_STRATEGY_V3 §2/§6).
//
// TRIGGER: schedule (every ~30 min is plenty; the strategy is deliberately low-frequency).
// ACTIONS (all onlyKeeper, all RE-VERIFIED on-chain within hardcoded bounds — INV-12):
//   1. rebalanceBase(id, t, true)  — ONLY when the pool's current tick has LEFT the base band
//      (out-of-range = the position stopped earning; the Vault's MAX_IL_BPS_PER_RECENTER,
//      TWAP and slippage clamps bound whatever this call can do).
//   2. skimIdle(id, t) + rebalanceLimit(id, t) — when the tranche has no LIMIT band yet
//      (fresh pools carry a single wide BASE band until the keeper builds the idle reserve
//      and deploys the limit band from it).
//
// EFFICIENCY DOCTRINE: every candidate action is SIMULATED first (eth_call as the keeper);
// a transaction is sent ONLY if the simulation succeeds. A calm pool costs zero gas — the
// keeper reads, decides "nothing to do", and exits. Fail-static per common.ts: if this
// keeper never runs, positions simply hold (they just stop adapting).
//
// DISCOVERY: pools are discovered from the hook's PoolRegistered events (no config list to
// maintain); a tranche is active iff its FeraShare totalSupply > 0.

import { FeraVaultAbi } from "../abis/FeraVault";
import { runOnce, log, type KeeperEnv } from "./common";

const VAULT = (process.env.FERA_VAULT_ADDRESS ?? "0xa8cF82797ecBC8C5cD5F83D60e189dbDc88D959a") as `0x${string}`;
const HOOK = (process.env.FERA_HOOK_ADDRESS ?? "0x96CE193F25db9b75743332bB7C94e545f1a225C3") as `0x${string}`;
const POOL_MANAGER = (process.env.UNIV4_POOL_MANAGER ?? "0x8366a39cc670b4001a1121b8f6a443a643e40951") as `0x${string}`;
const STATE_VIEW = (process.env.UNIV4_STATE_VIEW ?? "0xf3334192d15450cdd385c8b70e03f9a6bd9e673b") as `0x${string}`;
const START_BLOCK = BigInt(process.env.FERA_START_BLOCK ?? 12347590);
// Simulation identity when no signer is loaded (dry-run): the real keeper EOA, so
// onlyKeeper-gated eth_calls exercise the true path.
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

const modifyLiquidityEvent = {
  type: "event",
  name: "ModifyLiquidity",
  inputs: [
    { name: "id", type: "bytes32", indexed: true },
    { name: "sender", type: "address", indexed: true },
    { name: "tickLower", type: "int24", indexed: false },
    { name: "tickUpper", type: "int24", indexed: false },
    { name: "liquidityDelta", type: "int256", indexed: false },
    { name: "salt", type: "bytes32", indexed: false },
  ],
} as const;

const stateViewAbi = [
  {
    type: "function",
    name: "getSlot0",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
      { name: "protocolFee", type: "uint24" },
      { name: "lpFee", type: "uint24" },
    ],
  },
] as const;

const erc20SupplyAbi = [
  { type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

type Band = { lo: number; hi: number; liquidity: bigint };

/** Live bands for (pool) reconstructed from PoolManager ModifyLiquidity deltas (vault-sent). */
async function liveBands(env: KeeperEnv, poolId: `0x${string}`): Promise<Band[]> {
  const logs = await env.publicClient.getLogs({
    address: POOL_MANAGER,
    event: modifyLiquidityEvent,
    args: { id: poolId, sender: VAULT },
    fromBlock: START_BLOCK,
    toBlock: "latest",
  });
  const acc = new Map<string, Band>();
  for (const l of logs) {
    const { tickLower, tickUpper, liquidityDelta } = l.args as {
      tickLower: number; tickUpper: number; liquidityDelta: bigint;
    };
    const k = `${tickLower}:${tickUpper}`;
    const b = acc.get(k) ?? { lo: tickLower, hi: tickUpper, liquidity: 0n };
    b.liquidity += liquidityDelta;
    acc.set(k, b);
  }
  return [...acc.values()].filter((b) => b.liquidity > 0n);
}

/** simulate as the keeper; send only when the simulation succeeds (zero wasted gas). */
async function simulateThenSend(
  env: KeeperEnv,
  label: string,
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
      log("vault-strategy", "info", `DRY RUN — would send ${label}`, { poolId });
      return false;
    }
    const hash = await env.walletClient.writeContract(request);
    const rcpt = await env.publicClient.waitForTransactionReceipt({ hash });
    log("vault-strategy", rcpt.status === "success" ? "info" : "warn", `${label} ${rcpt.status}`, { poolId, hash });
    return rcpt.status === "success";
  } catch (e) {
    // Simulation revert = the Vault says "not needed / not allowed right now" (idle at
    // target, IL bound, TWAP gate…). That is the on-chain guard doing its job — log & skip.
    log("vault-strategy", "info", `${label} skipped (simulation reverted)`, {
      poolId,
      reason: String((e as Error).message ?? e).slice(0, 200),
    });
    return false;
  }
}

export async function tick(env: KeeperEnv): Promise<void> {
  const pools = await env.publicClient.getLogs({
    address: HOOK,
    event: poolRegisteredEvent,
    fromBlock: START_BLOCK,
    toBlock: "latest",
  });
  log("vault-strategy", "info", `discovered ${pools.length} pools`);

  for (const p of pools) {
    const poolId = (p.args as { poolId: `0x${string}` }).poolId;
    const [, tick] = await env.publicClient.readContract({
      address: STATE_VIEW,
      abi: stateViewAbi,
      functionName: "getSlot0",
      args: [poolId],
    });

    for (const t of [0, 1] as const) {
      // Active tranche? (tranche 1 exists on-chain but may be unseeded — skip supply 0.)
      let share: `0x${string}`;
      try {
        share = (await env.publicClient.readContract({
          address: VAULT,
          abi: FeraVaultAbi,
          functionName: "shareToken",
          args: [poolId, t],
        })) as `0x${string}`;
      } catch {
        continue;
      }
      const supply = await env.publicClient
        .readContract({ address: share, abi: erc20SupplyAbi, functionName: "totalSupply" })
        .catch(() => 0n);
      if (supply === 0n) continue;

      // NOTE: bands are per-POOL from PM logs (tranche attribution needs vault internals);
      // with one seeded tranche this is exact. Revisit when tranche 1 goes live.
      const bands = await liveBands(env, poolId);
      if (bands.length === 0) continue;
      const base = bands.reduce((w, b) => (b.hi - b.lo > w.hi - w.lo ? b : w));
      const outOfRange = tick < base.lo || tick >= base.hi;
      log("vault-strategy", "info", "pool state", {
        poolId, tranche: t, tick, baseLo: base.lo, baseHi: base.hi, bands: bands.length, outOfRange,
      });

      if (outOfRange) {
        // Price left the base band: position stopped earning. Recenter (self-swap allowed;
        // the Vault's IL/TWAP/slippage clamps bound the action).
        await simulateThenSend(env, "rebalanceBase", poolId, "rebalanceBase", [poolId, t, true]);
      } else if (bands.length < 2) {
        // No LIMIT band yet: build the idle reserve, then deploy the limit band from it.
        await simulateThenSend(env, "skimIdle", poolId, "skimIdle", [poolId, t]);
        await simulateThenSend(env, "rebalanceLimit", poolId, "rebalanceLimit", [poolId, t]);
      }
    }
  }
}

runOnce("vault-strategy", tick).then((code) => process.exit(code));
