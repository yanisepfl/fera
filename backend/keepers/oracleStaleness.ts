// KEEPER 4/4 — Oracle-staleness monitor (MASTER_SPEC §10).
//
// TRIGGER: continuous.
// ACTION: READ-ONLY. Reads each RWA feed's Chainlink latestRoundData().updatedAt and compares
// (now − updatedAt) against that feed's per-feed heartbeat (D-9: decimals + heartbeat are
// per-feed and MUST be parametrized, never assumed). Emits an alert / heartbeat when a feed is
// stale. Writes NOTHING on-chain.
//
// ON-CHAIN VERIFICATION BOUNDS (§10): "Read-only alerting; Vault fee logic clamps independently."
// The Vault's RWA fee path ALREADY handles a stale/failed oracle on-chain (oracle-fail → flat
// 300bp, never reverts — PARAMS.md). So this monitor is purely observational: if it dies, the
// Vault is still safe (fail-static). Its job is to page a human before users notice, and to feed
// the ops/ Prometheus `fera_oracle_seconds_since_update` gauge that drives the OracleStale alert.
//
// D-9: heartbeats/decimals come from a per-feed config (KEEPER_ORACLE_FEEDS), never hardcoded 8/18.

import { ChainlinkAggregatorAbi } from "../abis/competitors";
import { runOnce, log, heartbeat, type KeeperEnv } from "./common";

interface FeedConfig {
  symbol: string;
  address: `0x${string}`;
  heartbeatS: number; // per-feed (D-9)
  decimals?: number; // per-feed (D-9); read on-chain if omitted
}

function loadFeeds(): FeedConfig[] {
  const raw = process.env.KEEPER_ORACLE_FEEDS;
  if (!raw) return [];
  try {
    return (JSON.parse(raw) as FeedConfig[]).filter((f) => f.address && f.heartbeatS > 0);
  } catch {
    return [];
  }
}

export interface FeedStatus {
  symbol: string;
  address: string;
  updatedAt: number;
  secondsSinceUpdate: number;
  heartbeatS: number;
  stale: boolean;
  answer: string;
}

async function tick(env: KeeperEnv): Promise<void> {
  const feeds = loadFeeds();
  if (feeds.length === 0) {
    log("oracle-monitor", "warn", "no feeds configured (KEEPER_ORACLE_FEEDS) — nothing to monitor");
    return;
  }
  const now = Math.floor(Date.now() / 1000);
  const statuses: FeedStatus[] = [];
  for (const f of feeds) {
    const [, answer, , updatedAt] = (await env.publicClient.readContract({
      address: f.address,
      abi: ChainlinkAggregatorAbi,
      functionName: "latestRoundData",
      args: [],
    })) as [bigint, bigint, bigint, bigint, bigint];
    const ua = Number(updatedAt);
    const age = now - ua;
    // grace: allow 1 extra heartbeat before flagging (avoids flapping right at the boundary).
    const stale = age > f.heartbeatS * 2;
    const status: FeedStatus = {
      symbol: f.symbol,
      address: f.address,
      updatedAt: ua,
      secondsSinceUpdate: age,
      heartbeatS: f.heartbeatS,
      stale,
      answer: answer.toString(),
    };
    statuses.push(status);
    if (stale) log("oracle-monitor", "warn", "STALE feed", { ...status });
    else log("oracle-monitor", "info", "feed fresh", { symbol: f.symbol, age });
    if (answer <= 0n) log("oracle-monitor", "warn", "non-positive answer (Vault clamps to fail flat-fee)", { symbol: f.symbol });
  }
  // Persist the per-feed status for the ops/ Prometheus exporter (fera_oracle_seconds_since_update).
  heartbeat("oracle-monitor", true, { feeds: statuses });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runOnce("oracle-monitor", tick).then((code) => process.exit(code));
}

export { tick as oracleStalenessTick };
