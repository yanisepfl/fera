// Shared keeper infrastructure (MASTER_SPEC §10).
//
// FAIL-STATIC DOCTRINE (§10): "Keeper absence must fail-static (positions hold), never
// fail-open." Every keeper here is a THIN trigger whose action is RE-VERIFIED on-chain by the
// Vault/Distributor within hardcoded bounds (INV-12: keeper-scoped within hardcoded bounds). If a
// keeper crashes, is late, or is skipped, nothing bad happens — the Vault simply holds and the
// fee logic clamps independently. Two independent keeper providers run these (Deployment 5); the
// on-chain guards make double-submission safe (idempotent / one-shot per epoch or interval).
//
// This module provides: env-driven viem clients, structured JSON logging, a heartbeat file the
// ops/ Prometheus exporter reads (keeper-miss alerts), and a run wrapper that never throws out.

import { createPublicClient, createWalletClient, http, type PublicClient, type WalletClient, type Account } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

export interface KeeperEnv {
  rpcUrl: string;
  chainId: number;
  account?: Account;
  publicClient: PublicClient;
  walletClient?: WalletClient;
  dryRun: boolean;
}

export function loadEnv(): KeeperEnv {
  const rpcUrl = process.env.PONDER_RPC_URL_RH ?? process.env.KEEPER_RPC_URL ?? "http://127.0.0.1:8545";
  const chainId = Number(process.env.PONDER_CHAIN_ID ?? 42161);
  const dryRun = process.env.KEEPER_DRY_RUN !== "false"; // dry-run by DEFAULT (secure default)
  const publicClient = createPublicClient({ transport: http(rpcUrl) }) as PublicClient;

  let account: Account | undefined;
  let walletClient: WalletClient | undefined;
  const pk = process.env.KEEPER_PRIVATE_KEY;
  if (pk && !dryRun) {
    account = privateKeyToAccount(pk as `0x${string}`);
    walletClient = createWalletClient({ account, transport: http(rpcUrl) });
  }
  return { rpcUrl, chainId, account, publicClient, walletClient, dryRun };
}

export function log(keeper: string, level: "info" | "warn" | "error", msg: string, extra: Record<string, unknown> = {}) {
  const line = JSON.stringify({ ts: new Date().toISOString(), keeper, level, msg, ...replacer(extra) });
  if (level === "error") console.error(line);
  else console.log(line);
}

function replacer(o: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(o)) out[k] = typeof v === "bigint" ? v.toString() : v;
  return out;
}

// Heartbeat: ops/ Prometheus exporter turns "now - last success > interval" into a keeper-miss
// alert. Written on every successful tick so a stalled/crashed keeper goes stale (fail-static +
// observable).
export function heartbeat(keeper: string, ok: boolean, detail: Record<string, unknown> = {}) {
  const dir = process.env.KEEPER_HEARTBEAT_DIR ?? join(process.cwd(), ".keeper-heartbeats");
  try {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, `${keeper}.json`), JSON.stringify({ keeper, ok, ts: Math.floor(Date.now() / 1000), ...replacer(detail) }));
  } catch (e) {
    log(keeper, "warn", "heartbeat write failed", { err: String(e) });
  }
}

/** Randomized delay within [0, windowMs) — RWA MEV mitigation (§10, D-6). Deterministic-free. */
export function jitterMs(windowMs: number): number {
  return Math.floor(Math.random() * Math.max(0, windowMs));
}

/**
 * Run a keeper tick with fail-static semantics: any throw is logged + heartbeated as NOT-ok and
 * swallowed (the process exits non-zero for the supervisor, but never leaves a half-submitted
 * on-chain action — each keeper's write is a single idempotent tx re-verified on-chain).
 */
export async function runOnce(keeper: string, fn: (env: KeeperEnv) => Promise<void>): Promise<number> {
  const env = loadEnv();
  log(keeper, "info", "start", { chainId: env.chainId, dryRun: env.dryRun });
  try {
    await fn(env);
    heartbeat(keeper, true);
    log(keeper, "info", "ok");
    return 0;
  } catch (e) {
    heartbeat(keeper, false, { err: String(e) });
    log(keeper, "error", "tick failed (fail-static: no partial action left on-chain)", { err: String(e) });
    return 1;
  }
}

export const ZERO_ADDR = "0x0000000000000000000000000000000000000000" as const;
export function isUnset(a?: string): boolean {
  return !a || a.toLowerCase() === ZERO_ADDR;
}
