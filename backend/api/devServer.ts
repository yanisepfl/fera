// FERA pre-deployment LIVE-data API server.
//
// The real API is served by Ponder (api/index.ts) over the INDEXED on-chain store — but
// the FERA contracts are NOT deployed yet, so there is nothing to index. This server is
// the honest bridge until then: it serves the same §8 route surface the frontend consumes
// (frontend/lib/types.ts shapes — the fixtures/MSW wire format), with
//
//   REAL      market facts from GeckoTerminal for Robinhood Chain (api/marketData.ts):
//             token pairs, prices, 24h volume/change, underlying-pool TVL, price candles.
//   INACTIVE  everything vault-specific (vault TVL, APRs, dynamic fee, positions, epochs,
//             staking, vesting, emissions, revenue): explicit zeros / empty lists, flagged
//             machine-readably with `vaultLive: false`. NOTHING vault-side is fabricated.
//
// Zero dependencies beyond node:http + built-in fetch (Node >= 20). Run:
//
//   npm run api:dev                 # http://localhost:42070
//   PORT=8788 npm run api:dev       # custom port
//
// Point the frontend at it:  NEXT_PUBLIC_API_URL=http://localhost:42070 npm run dev
// (in frontend/ — MSW/fixtures are automatically bypassed when the URL is set).

import http from "node:http";
import { topPools, poolByAddress, toDetail, ohlcv } from "./marketData";

const PORT = Number(process.env.PORT ?? 42070);

// All values the §8 conventions expect for a not-yet-live protocol: zeros and empties,
// never invented numbers. `vaultLive:false` is the machine-readable flag the UI keys on.
const NOT_LIVE = { vaultLive: false as const };

type Handler = (
  params: Record<string, string>,
  query: URLSearchParams,
) => Promise<{ status: number; body: unknown }>;

const ok = (body: unknown) => ({ status: 200, body });
const notFound = (error: string) => ({ status: 404, body: { error, ...NOT_LIVE } });

// ---- routes (§8 surface, frontend wire format) ------------------------------

const routes: [RegExp, string[], Handler][] = [
  [/^\/health$/, [], async () => ok({ ok: true, mode: "pre-deployment-live-market", ...NOT_LIVE })],

  // GET /pools — REAL top Robinhood Chain pools by 24h volume; vault fields inactive.
  [/^\/pools$/, [], async () => ok(await topPools())],

  // GET /pools/:poolId/ohlcv?timeframe=hour&aggregate=1&limit=168 — REAL price candles.
  [
    /^\/pools\/([^/]+)\/ohlcv$/,
    ["poolId"],
    async (p, q) => {
      const pool = await poolByAddress(p.poolId);
      if (!pool) return notFound("pool not found");
      const candles = await ohlcv(
        p.poolId,
        q.get("timeframe") ?? "hour",
        Number(q.get("aggregate") ?? 1),
        Number(q.get("limit") ?? 168),
      );
      return ok(candles);
    },
  ],

  // GET /pools/:poolId/depth — no FERA vault depth exists yet; nothing to compare.
  [
    /^\/pools\/([^/]+)\/depth$/,
    ["poolId"],
    async (p) => {
      const pool = await poolByAddress(p.poolId);
      if (!pool) return notFound("pool not found");
      return ok({
        poolId: pool.poolId,
        pair: `${pool.token0.symbol}/${pool.token1.symbol}`,
        venues: [], // honest: FERA depth is not live; we serve no fabricated comparison
        ...NOT_LIVE,
      });
    },
  ],

  // GET /pools/:poolId — REAL market detail; vault mechanics inactive.
  [
    /^\/pools\/([^/]+)$/,
    ["poolId"],
    async (p) => {
      const pool = await poolByAddress(p.poolId);
      return pool ? ok(toDetail(pool)) : notFound("pool not found");
    },
  ],

  // ---- vault-scoped surfaces: nothing exists on-chain yet → zeros/empties ----
  [/^\/positions\/([^/]+)$/, ["account"], async () => ok([])],
  [
    /^\/epochs\/current$/,
    [],
    async () =>
      ok({ epochId: 0, endsAt: 0, feesPaid: 0, feesEarned: 0, projectedEsFera: "0", ...NOT_LIVE }),
  ],
  [
    /^\/epochs\/(\d+)\/proof\/([^/]+)$/,
    ["id", "account"],
    async () => notFound("no epoch has been finalized — the vault is not deployed yet"),
  ],
  [
    /^\/staking\/([^/]+)$/,
    ["account"],
    async () => ok({ sFera: 0, boost: 1, multiplierPoints: 0, revenueShareApr: 0, ...NOT_LIVE }),
  ],
  [/^\/vesting\/([^/]+)$/, ["account"], async () => ok([])],
  [/^\/transparency\/emissions$/, [], async () => ok({ series: [], ...NOT_LIVE })],
  [
    /^\/transparency\/revenue$/,
    [],
    async () => ok({ toStakers: 0, toTreasury: 0, toOps: 0, byToken: [], ...NOT_LIVE }),
  ],
];

// ---- tiny server -------------------------------------------------------------

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);
  const path = url.pathname.replace(/\/+$/, "") || "/";

  // CORS: a public, read-only dev API — the browser frontend runs on another origin.
  res.setHeader("access-control-allow-origin", "*");
  res.setHeader("access-control-allow-methods", "GET, OPTIONS");
  res.setHeader("access-control-allow-headers", "accept, content-type");
  if (req.method === "OPTIONS") {
    res.writeHead(204).end();
    return;
  }
  if (req.method !== "GET") {
    res.writeHead(405, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "GET only" }));
    return;
  }

  for (const [re, names, handler] of routes) {
    const m = path.match(re);
    if (!m) continue;
    const params: Record<string, string> = {};
    names.forEach((n, i) => (params[n] = decodeURIComponent(m[i + 1] ?? "")));
    try {
      const { status, body } = await handler(params, url.searchParams);
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    } catch (err) {
      // Upstream (GeckoTerminal) outage with no cached snapshot: say so — don't invent.
      res.writeHead(503, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          error: "live market data source unreachable",
          detail: err instanceof Error ? err.message : String(err),
          ...NOT_LIVE,
        }),
      );
    }
    return;
  }

  res.writeHead(404, { "content-type": "application/json" });
  res.end(JSON.stringify({ error: `no route ${path}` }));
});

server.listen(PORT, () => {
  console.log(`[fera api:dev] live market data (pre-deployment) on http://localhost:${PORT}`);
  console.log(`[fera api:dev] source: GeckoTerminal / Robinhood Chain — vault fields inactive (vaultLive:false)`);
  console.log(`[fera api:dev] frontend: NEXT_PUBLIC_API_URL=http://localhost:${PORT} npm run dev`);
});
