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
//   RECORDED  Terms-of-Service acceptances (POST /tos/accept, GET /tos/status): a durable,
//             signature-verified ledger of who accepted which ToS version (api/tos*.ts).
//
// Hardening (this is a public dev endpoint): CORS is an explicit allow-list, every route
// param/query is validated before use (no unchecked string ever reaches the GeckoTerminal
// URL — SSRF/param-injection guard), requests are rate-limited per IP (token bucket), and
// security headers (nosniff / no-referrer / DENY / locked CSP) are set on every response.
//
// Zero dependencies beyond node:http + built-in fetch + viem (already a dep). Run:
//
//   npm run api:dev                 # http://localhost:42070
//   PORT=8788 npm run api:dev       # custom port
//
// Point the frontend at it:  NEXT_PUBLIC_API_URL=http://localhost:42070 npm run dev
// (in frontend/ — MSW/fixtures are automatically bypassed when the URL is set).

import http from "node:http";
import { topPools, poolByAddress, toDetail, ohlcv } from "./marketData";
import { createTosStore, type TosStore } from "./tosStore";
import { handleAccept, handleStatus } from "./tos";

const PORT = Number(process.env.PORT ?? 42070);

// All values the §8 conventions expect for a not-yet-live protocol: zeros and empties,
// never invented numbers. `vaultLive:false` is the machine-readable flag the UI keys on.
const NOT_LIVE = { vaultLive: false as const };

// ---- config -----------------------------------------------------------------

// CORS: browsers may call this API only from an explicit allow-list of origins.
// Default is the local frontend; set FERA_ALLOWED_ORIGINS to a comma-separated list
// (e.g. "https://app.fera.fi,https://fera.fi") for a real deployment.
const ALLOWED_ORIGINS = new Set(
  (process.env.FERA_ALLOWED_ORIGINS ?? "http://localhost:3000")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
);

// Per-IP token bucket: FERA_RATE_BURST tokens, refilled FERA_RATE_REFILL_PER_SEC/sec.
// Defaults (120 burst, 8/sec) comfortably clear a normal browser session while making it
// hard to hammer the endpoint or exhaust GeckoTerminal's free quota through us.
const RATE_BURST = Math.max(1, Number(process.env.FERA_RATE_BURST ?? 120));
const RATE_REFILL = Math.max(0.1, Number(process.env.FERA_RATE_REFILL_PER_SEC ?? 8));
// XFF is spoofable, so we key on the socket peer by default. Set FERA_TRUST_PROXY=1 only
// when running behind a trusted reverse proxy that sets X-Forwarded-For.
const TRUST_PROXY = process.env.FERA_TRUST_PROXY === "1";

// ---- validation -------------------------------------------------------------

// Pool ids are venue pool addresses / GT pool ids. This charset admits addresses and GT
// ids while forbidding '/', '.', '%', '?', '#' and whitespace — so a decoded value can
// never traverse paths or inject query params into the upstream GeckoTerminal URL.
const POOL_ID_RE = /^[a-zA-Z0-9_-]{1,100}$/;
const TIMEFRAMES = new Set(["minute", "hour", "day"]);

const validPoolId = (s: string) => POOL_ID_RE.test(s);

/** Parse a strictly-integer query value in [min,max]; null if absent-and-defaulted, or invalid. */
function intInRange(
  raw: string | null,
  fallback: number,
  min: number,
  max: number,
): number | null {
  if (raw === null) return fallback;
  if (!/^-?\d+$/.test(raw)) return null; // reject "1e3", "0x1", " 5 ", floats, junk
  const n = Number(raw);
  return n >= min && n <= max ? n : null;
}

// ---- rate limiter (in-memory token bucket per IP) ---------------------------

interface Bucket {
  tokens: number;
  last: number; // ms
}
const buckets = new Map<string, Bucket>();
const MAX_BUCKETS = 20_000;

function clientIp(req: http.IncomingMessage): string {
  if (TRUST_PROXY) {
    const xff = req.headers["x-forwarded-for"];
    const first = Array.isArray(xff) ? xff[0] : xff?.split(",")[0];
    if (first) return first.trim();
  }
  return req.socket.remoteAddress ?? "unknown";
}

function rateLimitOk(ip: string): boolean {
  const now = Date.now();
  let b = buckets.get(ip);
  if (!b) {
    if (buckets.size >= MAX_BUCKETS) {
      // Bound memory: drop the oldest-inserted bucket (Map preserves insertion order).
      const oldest = buckets.keys().next().value;
      if (oldest !== undefined) buckets.delete(oldest);
    }
    b = { tokens: RATE_BURST, last: now };
    buckets.set(ip, b);
  }
  b.tokens = Math.min(RATE_BURST, b.tokens + ((now - b.last) / 1000) * RATE_REFILL);
  b.last = now;
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}

// ---- response helpers -------------------------------------------------------

function setSecurityHeaders(res: http.ServerResponse) {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("X-Frame-Options", "DENY");
  // A JSON API loads no resources; lock the CSP all the way down.
  res.setHeader("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
}

/** Set CORS headers iff the request Origin is allow-listed. Returns nothing (browser enforces). */
function applyCors(req: http.IncomingMessage, res: http.ServerResponse) {
  const origin = req.headers.origin;
  res.setHeader("Vary", "Origin");
  if (origin && ALLOWED_ORIGINS.has(origin)) {
    res.setHeader("Access-Control-Allow-Origin", origin);
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "accept, content-type");
    res.setHeader("Access-Control-Max-Age", "600");
  }
}

function send(res: http.ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

/** Read a length-capped request body (default 16 KiB). Rejects oversized payloads. */
function readBody(req: http.IncomingMessage, limit = 16_384): Promise<string> {
  return new Promise((resolve, reject) => {
    let data = "";
    let size = 0;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error("payload too large"));
        req.destroy();
        return;
      }
      data += chunk.toString("utf8");
    });
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}

// ---- market routes (§8 surface, frontend wire format) -----------------------

const ok = (body: unknown) => ({ status: 200, body });
const notFound = (error: string) => ({ status: 404, body: { error, ...NOT_LIVE } });
const badRequest = (error: string) => ({ status: 400, body: { error } });

type Handler = (
  params: Record<string, string>,
  query: URLSearchParams,
) => Promise<{ status: number; body: unknown }>;

const routes: [RegExp, string[], Handler][] = [
  [/^\/health$/, [], async () => ok({ ok: true, mode: "pre-deployment-live-market", tos: tosStore.kind, ...NOT_LIVE })],

  // GET /pools — REAL top Robinhood Chain pools by 24h volume; vault fields inactive.
  [/^\/pools$/, [], async () => ok(await topPools())],

  // GET /pools/:poolId/ohlcv?timeframe=hour&aggregate=1&limit=168 — REAL price candles.
  [
    /^\/pools\/([^/]+)\/ohlcv$/,
    ["poolId"],
    async (p, q) => {
      if (!validPoolId(p.poolId)) return badRequest("invalid poolId");
      const timeframe = q.get("timeframe") ?? "hour";
      if (!TIMEFRAMES.has(timeframe)) return badRequest("timeframe must be minute|hour|day");
      const aggregate = intInRange(q.get("aggregate"), 1, 1, 60);
      if (aggregate === null) return badRequest("aggregate must be an integer in [1,60]");
      const limit = intInRange(q.get("limit"), 168, 1, 1000);
      if (limit === null) return badRequest("limit must be an integer in [1,1000]");
      const pool = await poolByAddress(p.poolId);
      if (!pool) return notFound("pool not found");
      return ok(await ohlcv(p.poolId, timeframe, aggregate, limit));
    },
  ],

  // GET /pools/:poolId/depth — no FERA vault depth exists yet; nothing to compare.
  [
    /^\/pools\/([^/]+)\/depth$/,
    ["poolId"],
    async (p) => {
      if (!validPoolId(p.poolId)) return badRequest("invalid poolId");
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
      if (!validPoolId(p.poolId)) return badRequest("invalid poolId");
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

// ---- server -----------------------------------------------------------------

const tosStore: TosStore = await createTosStore();

const server = http.createServer(async (req, res) => {
  setSecurityHeaders(res);
  applyCors(req, res);

  // Preflight: answer before rate-limiting/auth so browsers can negotiate CORS.
  if (req.method === "OPTIONS") {
    res.writeHead(204).end();
    return;
  }

  if (!rateLimitOk(clientIp(req))) {
    res.setHeader("Retry-After", "1");
    send(res, 429, { error: "rate limit exceeded" });
    return;
  }

  const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);
  const path = url.pathname.replace(/\/+$/, "") || "/";

  // ---- Terms-of-Service ledger ----------------------------------------------
  if (path === "/tos/accept") {
    if (req.method !== "POST") return send(res, 405, { error: "POST only" });
    let parsed: unknown;
    try {
      parsed = JSON.parse((await readBody(req)) || "{}");
    } catch {
      return send(res, 400, { error: "invalid JSON body" });
    }
    try {
      const { status, body } = await handleAccept(tosStore, parsed, {
        ip: clientIp(req),
        userAgent: (req.headers["user-agent"] as string) ?? undefined,
      });
      return send(res, status, body);
    } catch (err) {
      return send(res, 500, { error: "failed to record acceptance", detail: String(err) });
    }
  }
  if (path === "/tos/status") {
    if (req.method !== "GET") return send(res, 405, { error: "GET only" });
    const { status, body } = await handleStatus(
      tosStore,
      url.searchParams.get("address"),
      url.searchParams.get("version"),
    );
    return send(res, status, body);
  }

  // ---- market / §8 surface (GET only) ---------------------------------------
  if (req.method !== "GET") {
    return send(res, 405, { error: "GET only" });
  }

  for (const [re, names, handler] of routes) {
    const m = path.match(re);
    if (!m) continue;
    const params: Record<string, string> = {};
    try {
      names.forEach((n, i) => (params[n] = decodeURIComponent(m[i + 1] ?? "")));
    } catch {
      return send(res, 400, { error: "malformed URL encoding" });
    }
    try {
      const { status, body } = await handler(params, url.searchParams);
      return send(res, status, body);
    } catch (err) {
      // Upstream (GeckoTerminal) outage with no cached snapshot: say so — don't invent.
      return send(res, 503, {
        error: "live market data source unreachable",
        detail: err instanceof Error ? err.message : String(err),
        ...NOT_LIVE,
      });
    }
  }

  send(res, 404, { error: `no route ${path}` });
});

server.listen(PORT, () => {
  console.log(`[fera api:dev] live market data (pre-deployment) on http://localhost:${PORT}`);
  console.log(`[fera api:dev] source: GeckoTerminal / Robinhood Chain — vault fields inactive (vaultLive:false)`);
  console.log(`[fera api:dev] ToS ledger: ${tosStore.kind} · CORS allow-list: ${[...ALLOWED_ORIGINS].join(", ")}`);
  console.log(`[fera api:dev] frontend: NEXT_PUBLIC_API_URL=http://localhost:${PORT} npm run dev`);
});
