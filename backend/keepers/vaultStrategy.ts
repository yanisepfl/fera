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

const WWETH = (process.env.FERA_WWETH ?? "0x0bd7d308f8e1639fab988df18a8011f41eacad73").toLowerCase();
const STATE_VIEW = (process.env.UNIV4_STATE_VIEW ?? "0xf3334192d15450cdd385c8b70e03f9a6bd9e673b") as `0x${string}`;
const stateViewAbi = [
  { type: "function", name: "getSlot0", stateMutability: "view", inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ type: "uint160" }, { type: "int24" }, { type: "uint24" }, { type: "uint24" }] },
] as const;

// --- Cross-venue price guard (option A) ---------------------------------------------------------
// Before acting on a pool, sanity-check its on-chain price against the DEEP external market
// (GeckoTerminal aggregate). If they diverge past a threshold the pool is either being manipulated
// to game a rebalance, or simply mispriced — either way, do NOT recenter/redeploy at that price;
// external arbers will correct it (they pay our fee to do so) and the keeper acts on the next tick.
//
// FAIL-OPEN by construction so the keeper is NEVER stuck skipping: the guard returns "clear"
// (proceed) whenever it can't get BOTH prices, when the divergence is within threshold, or when
// disabled (KEEPER_ARB_CHECK_BPS=0). It only blocks on a *confirmed* large divergence with both
// prices in hand. On top of that, the vault's own spot-vs-TWAP gate is the on-chain backstop.
// Assumes an 18-dec memecoin vs 18-dec wWETH (all current pools) — skips the check otherwise.
const ARB_CHECK_BPS = Number(process.env.KEEPER_ARB_CHECK_BPS ?? 300); // default ±3%

async function marketPriceWeth(memecoin: string): Promise<number | null> {
  try {
    const gt = (a: string) =>
      fetch(`https://api.geckoterminal.com/api/v2/networks/robinhood/tokens/${a}`, {
        headers: { accept: "application/json" },
      }).then((r) => r.json() as Promise<{ data?: { attributes?: { price_usd?: string } } }>);
    const [m, w] = await Promise.all([gt(memecoin), gt(WWETH)]);
    const mp = Number(m?.data?.attributes?.price_usd);
    const wp = Number(w?.data?.attributes?.price_usd);
    if (!(mp > 0) || !(wp > 0)) return null;
    return mp / wp; // memecoin price denominated in wWETH
  } catch {
    return null;
  }
}

async function poolPriceWeth(env: KeeperEnv, poolId: `0x${string}`, q0: boolean): Promise<number | null> {
  try {
    const slot = (await env.publicClient.readContract({
      address: STATE_VIEW, abi: stateViewAbi, functionName: "getSlot0", args: [poolId],
    })) as readonly [bigint, number, number, number];
    const p = (Number(slot[0]) / 2 ** 96) ** 2; // raw token1/token0 (18/18 dec cancel)
    if (!(p > 0)) return null;
    return q0 ? 1 / p : p; // q0: token0=wWETH => p is meme/wWETH => meme price = 1/p; else p already meme-priced
  } catch {
    return null;
  }
}

/** null = clear to act; otherwise the divergence detail (skip acting on the pool this tick). */
async function priceGuard(
  env: KeeperEnv, poolId: `0x${string}`, memecoin: string, q0: boolean,
): Promise<{ ours: number; ref: number; divBps: number } | null> {
  if (ARB_CHECK_BPS <= 0) return null; // disabled
  const [ref, ours] = await Promise.all([marketPriceWeth(memecoin), poolPriceWeth(env, poolId, q0)]);
  if (ref == null || ours == null) return null; // fail-open: can't compare => let the vault's TWAP gate decide
  const divBps = Math.round((Math.abs(ours - ref) / ref) * 10_000);
  return divBps > ARB_CHECK_BPS ? { ours, ref, divBps } : null;
}

/// Audit finding (medium): a `PoolNotKeeperActive` revert means the owner has not (or forgot to)
/// call `setKeeperActive` for this pool — every automated action is permanently a no-op until they
/// do. That is NOT the same "nothing to do this tick" as `NotOutOfRange`/`OorNotPersistent`/
/// `TwapStale`/idle-at-target, which are expected, healthy, and self-resolving. Folding both into
/// one `info`-level "skipped" log (as this used to) makes a silently un-activated pool
/// indistinguishable from a calm one in the logs — this is the actual bug the finding reports.
const POOL_NOT_KEEPER_ACTIVE = "PoolNotKeeperActive";

function revertReason(e: unknown): string {
  // viem decodes a known custom error (present in FeraVaultAbi) into the message as
  // `<ErrorName>()` — fall back to the generic `Error: <Name>` shape / "reverted" for anything the
  // ABI can't decode (e.g. a stale ABI, or a revert with no reason string at all).
  const msg = String((e as Error)?.message ?? e);
  return msg.match(/\b(\w+)\(\)/)?.[1] ?? msg.match(/Error: (\w+)/)?.[1] ?? "reverted";
}

/** simulate as the keeper; send only when the simulation succeeds (zero wasted gas). */
async function simulateThenSend(
  env: KeeperEnv,
  poolId: `0x${string}`,
  functionName: "skimIdle" | "rebalanceLimit" | "rebalanceBase",
  args: readonly unknown[],
  notKeeperActive: Set<`0x${string}`>,
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
    const reason = revertReason(e);
    if (reason === POOL_NOT_KEEPER_ACTIVE) {
      // NOT ordinary no-op noise: the owner has never (or no longer) activated this pool. warn so
      // this is distinguishable from a healthy idle tick in anything scraping these logs, and
      // record it so the tick-level heartbeat surfaces it too (see ops/metrics.ts, ops/alerts.yml).
      notKeeperActive.add(poolId);
      log("vault-strategy", "warn", `${functionName} skipped — pool is NOT keeperActive`, {
        poolId,
        hint: "owner has not called setKeeperActive(poolId, true) for this pool — see FeraVault.sol keeperActive NatSpec",
      });
      return false;
    }
    // Any OTHER simulation revert = the vault says "not needed / not yet" (NotOutOfRange,
    // OorNotPersistent, TwapStale, idle at target…). Expected — log at info and skip.
    log("vault-strategy", "info", `${functionName} skipped`, { poolId, reason });
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

export async function tick(env: KeeperEnv): Promise<Record<string, unknown>> {
  const pools = await env.publicClient.getLogs({
    address: HOOK, event: poolRegisteredEvent, fromBlock: START_BLOCK, toBlock: "latest",
  });
  // Populated by simulateThenSend when a pool reverts with PoolNotKeeperActive (audit finding,
  // medium) — surfaced below as both a tick-level warn log and heartbeat detail, instead of being
  // folded into ordinary "nothing to do" noise.
  const notKeeperActive = new Set<`0x${string}`>();
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
    const args = p.args as { poolId: `0x${string}`; token0: string; token1: string };
    const poolId = args.poolId;
    // Cross-venue price guard (per pool): if our price is far from the deep market, don't ACT on
    // the pool this tick (recenter/skim/redeploy) — but ALWAYS keep the dwell clock in sync so the
    // moment it reprices we're ready. Fail-open (see priceGuard) so this never permanently stalls.
    const q0 = args.token0.toLowerCase() === WWETH;
    const memecoin = q0 ? args.token1 : args.token0;
    const diverged = await priceGuard(env, poolId, memecoin, q0);
    if (diverged) {
      log("vault-strategy", "warn", "price diverges from market — holding off rebalance (arb/manipulation guard)", {
        poolId, ourWeth: diverged.ours.toPrecision(4), mktWeth: diverged.ref.toPrecision(4), divBps: diverged.divBps,
      });
    }

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

      await syncDwellClock(env, poolId, t); // 1. dwell clock — ALWAYS (even when diverged)
      if (diverged) continue;               // hold off recenter/skim/limit while mispriced
      await simulateThenSend(env, poolId, "rebalanceBase", [poolId, t, true], notKeeperActive); // 2. recenter base if due
      if (doSkimLimit) {                                                       // 3+4. throttled ~daily
        await simulateThenSend(env, poolId, "skimIdle", [poolId, t], notKeeperActive);
        await simulateThenSend(env, poolId, "rebalanceLimit", [poolId, t], notKeeperActive);
      }
    }
  }

  if (notKeeperActive.size > 0) {
    log("vault-strategy", "warn", `${notKeeperActive.size} pool(s) NOT keeper-active — automated actions are no-ops on them`, {
      poolIds: [...notKeeperActive],
    });
  }
  return { poolsNotKeeperActive: [...notKeeperActive] };
}

runOnce("vault-strategy", tick).then((code) => process.exit(code));
