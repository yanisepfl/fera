// REST/JSON routes — MASTER_SPEC §8 data contract (D-2: REST, shapes in shapes.ts are the
// contract). Thin handlers: parse params, call the Store / proof loader, overlay the LIVE
// dynamic fee, return the §8 shape. Errors → 4xx/5xx JSON; bigints are pre-stringified by the
// store, with bigintReplacer as a safety net.

import { Hono } from "hono";
import type { Store } from "./store";
import type { LiveFeeReader } from "./liveFee";
import { proofsFor } from "./proofs";
import { ohlcv } from "./marketData";
import { bigintReplacer } from "./serialize";
import type { Address, Hex } from "./shapes";

export interface RouteDeps {
  store: Store;
  liveFee: LiveFeeReader;
}

const isHex32 = (s: string) => /^0x[0-9a-fA-F]{64}$/.test(s);
const isAddress = (s: string) => /^0x[0-9a-fA-F]{40}$/.test(s);

export function mountRoutes(app: Hono, deps: RouteDeps): Hono {
  const { store, liveFee } = deps;
  const json = (c: any, body: unknown, status = 200) =>
    c.newResponse(JSON.stringify(body, bigintReplacer), status, { "content-type": "application/json" });

  // NOTE: no custom /health here — Ponder 0.9 reserves /health (+ /metrics, /status, /ready)
  // for internal use and fails the build if an API function registers it. Ponder itself serves
  // GET /health (200 once the app is live). The pre-deployment devServer keeps its own /health.

  // GET /pools — list w/ LIVE fee overlay (read-through cached).
  app.get("/pools", async (c) => {
    const { items, raw } = await store.pools();
    const byId = new Map(raw.map((r) => [r.id.toLowerCase(), r]));
    for (const it of items) {
      const r = byId.get(it.poolId.toLowerCase());
      const live = await liveFee.feeFor(it.poolId, r?.currentFeePips ?? it.currentFeePips);
      it.currentFeePips = live.feePips;
      it.currentFeeSource = live.source;
    }
    return json(c, items);
  });

  // GET /pools/:poolId
  app.get("/pools/:poolId", async (c) => {
    const poolId = c.req.param("poolId");
    if (!isHex32(poolId)) return json(c, { error: "poolId must be a bytes32 hex" }, 400);
    const detail = await store.pool(poolId as Hex);
    if (!detail) return json(c, { error: "pool not found" }, 404);
    const live = await liveFee.feeFor(detail.poolId, detail.currentFeePips);
    detail.currentFeePips = live.feePips;
    detail.currentFeeSource = live.source;
    return json(c, detail);
  });

  // GET /pools/:poolId/ohlcv?timeframe=minute|hour|day&aggregate=1&limit=168 — REAL venue
  // price candles (GeckoTerminal pass-through; v4 poolIds are first-class GT pool ids on the
  // robinhood network). Cached ~2min in marketData. On upstream miss/error we serve [] —
  // the frontend simply hides the price-history card (never fabricated candles).
  app.get("/pools/:poolId/ohlcv", async (c) => {
    const poolId = c.req.param("poolId");
    if (!isHex32(poolId)) return json(c, { error: "poolId must be a bytes32 hex" }, 400);
    const timeframe = c.req.query("timeframe") ?? "hour";
    if (!["minute", "hour", "day"].includes(timeframe)) {
      return json(c, { error: "timeframe must be minute|hour|day" }, 400);
    }
    const aggregate = Number(c.req.query("aggregate") ?? 1);
    const limit = Number(c.req.query("limit") ?? 168);
    if (!Number.isInteger(aggregate) || aggregate < 1 || aggregate > 60) {
      return json(c, { error: "aggregate must be an integer in [1,60]" }, 400);
    }
    if (!Number.isInteger(limit) || limit < 1 || limit > 1000) {
      return json(c, { error: "limit must be an integer in [1,1000]" }, 400);
    }
    try {
      return json(c, await ohlcv(poolId, timeframe, aggregate, limit));
    } catch {
      return json(c, []);
    }
  });

  // GET /pools/:poolId/depth
  app.get("/pools/:poolId/depth", async (c) => {
    const poolId = c.req.param("poolId");
    if (!isHex32(poolId)) return json(c, { error: "poolId must be a bytes32 hex" }, 400);
    const depth = await store.depth(poolId as Hex);
    if (!depth) return json(c, { error: "pool not found" }, 404);
    return json(c, depth);
  });

  // GET /positions/:account
  app.get("/positions/:account", async (c) => {
    const account = c.req.param("account");
    if (!isAddress(account)) return json(c, { error: "account must be an address" }, 400);
    return json(c, await store.positions(account as Address));
  });

  // GET /epochs/current  (optional ?account=0x.. to scope feesPaid)
  app.get("/epochs/current", async (c) => {
    const account = c.req.query("account");
    if (account && !isAddress(account)) return json(c, { error: "bad account" }, 400);
    return json(c, await store.epochCurrent(account as Address | undefined));
  });

  // GET /epochs/:id/proof/:account  (optional ?kind=0|1)
  app.get("/epochs/:id/proof/:account", async (c) => {
    const id = c.req.param("id");
    const account = c.req.param("account");
    if (!/^\d+$/.test(id)) return json(c, { error: "epoch id must be a non-negative integer" }, 400);
    if (!isAddress(account)) return json(c, { error: "account must be an address" }, 400);
    const kindStr = c.req.query("kind");
    const kind = kindStr === undefined ? undefined : Number(kindStr);
    if (kind !== undefined && kind !== 0 && kind !== 1) return json(c, { error: "kind must be 0 or 1" }, 400);
    const res = proofsFor(id, account as Address, kind);
    // HONESTY GUARD: only serve a bundle whose root is actually POSTED on-chain (indexed from
    // Distributor:RootPosted) and matches byte-for-byte. Otherwise (dry-run bundle, not yet
    // posted, or drift) answer the §8 "no proofs" shape — never a fabricated/unclaimable proof.
    const posted = await store.epochPostedRoot(BigInt(id));
    if (!posted || !res.root || posted.toLowerCase() !== res.root.toLowerCase()) {
      return json(c, { epochId: id, account, root: null, claims: [] });
    }
    return json(c, res);
  });

  // GET /staking/:account
  app.get("/staking/:account", async (c) => {
    const account = c.req.param("account");
    if (!isAddress(account)) return json(c, { error: "account must be an address" }, 400);
    return json(c, await store.staking(account as Address));
  });

  // GET /vesting/:account — F-3 / §8 (v0.2): [{grantId, amount, startTs, endTs, vested,
  // claimable}], amounts as raw 18-dec wei strings (conventions v0.2).
  app.get("/vesting/:account", async (c) => {
    const account = c.req.param("account");
    if (!isAddress(account)) return json(c, { error: "account must be an address" }, 400);
    return json(c, await store.vesting(account as Address));
  });

  // GET /transparency/emissions
  app.get("/transparency/emissions", async (c) => json(c, await store.emissions()));

  // GET /transparency/revenue
  app.get("/transparency/revenue", async (c) => json(c, await store.revenue()));

  return app;
}
