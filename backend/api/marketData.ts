// LIVE market data for Robinhood Chain, sourced from GeckoTerminal's free public API
// (network id `robinhood`). Used by api/devServer.ts to serve the frontend REAL market
// facts BEFORE the FERA contracts are deployed.
//
// HONESTY CONTRACT (hard requirement):
//   - Everything under `market` is a MARKET fact fetched live from GeckoTerminal:
//     token pair, base price, 24h volume, 24h price change, the UNDERLYING pool's TVL,
//     trade counts, venue. Nothing here is invented.
//   - Every VAULT-specific field (vault TVL, share price, fee/emissions APR, dynamic
//     fee, depth-vs-best, tranches) has NO on-chain counterpart yet (no deployment),
//     so it is served as an explicit zero with `vaultLive: false`. The frontend renders
//     those as quiet "opens at launch" states — never as numbers.
//
// Politeness: GeckoTerminal's free tier allows ~30 req/min. We cache in-memory with a
// ~60s TTL, deduplicate concurrent fetches (single-flight), and fall back to the last
// good snapshot (marked by `fetchedAt`) if the upstream errors. Worst case steady-state
// load: 1 pool-list call/min + 1 OHLCV call per charted pool per 2 min.
//
// Docs: https://api.geckoterminal.com/docs (v2, no API key required).

const GT_BASE = process.env.FERA_GT_BASE ?? "https://api.geckoterminal.com/api/v2";
// Network id is an operator-set constant (never user input). Validate its charset anyway
// so a misconfigured env can't inject path/query segments into the upstream URL.
const NETWORK = (() => {
  const n = process.env.FERA_MARKET_NETWORK ?? "robinhood";
  if (!/^[a-z0-9_-]{1,40}$/.test(n)) throw new Error(`invalid FERA_MARKET_NETWORK: ${n}`);
  return n;
})();

// SSRF/param-injection guard for the one piece of user-controlled data that reaches the
// upstream URL: the pool address/id. Callers (api/devServer.ts) already reject bad ids with
// 400; this is defense-in-depth so marketData is safe even if called from elsewhere.
const POOL_ID_RE = /^[a-zA-Z0-9_-]{1,100}$/;
const encPoolId = (address: string): string => {
  if (!POOL_ID_RE.test(address)) throw new Error(`invalid pool id: ${address}`);
  return encodeURIComponent(address);
};
const TOP_N = Math.min(20, Number(process.env.FERA_MARKET_TOP_N ?? 10));
const POOLS_TTL_MS = Number(process.env.FERA_MARKET_TTL_MS ?? 60_000);
const OHLCV_TTL_MS = Number(process.env.FERA_MARKET_OHLCV_TTL_MS ?? 120_000);
const FETCH_TIMEOUT_MS = 15_000;

// ---------------------------------------------------------------------------
// Shapes served to the frontend. These mirror the §8 shapes AS CONSUMED by
// frontend/lib/types.ts (the fixtures/MSW wire format: numbers + regime strings),
// because the dev server's one job is to feed that UI real data pre-deployment.
// The indexed Ponder API (api/shapes.ts) keeps the conventions-v0.2 string format;
// reconciling the two is the tracked FE/BE follow-up, not this module's concern.
// ---------------------------------------------------------------------------

export interface TokenOut {
  address: string;
  symbol: string;
  decimals: number;
}

/** REAL market facts for the pool's underlying venue. Every field is fetched. */
export interface PoolMarketStats {
  priceUsd: number; // base-token price in USD
  priceChange24h: number; // decimal fraction (-0.221 = -22.1%)
  volume24hUsd: number;
  tvlUsd: number; // the UNDERLYING pool's reserve in USD (NOT vault TVL)
  txns24h: number; // buys + sells over 24h
  dex: string; // GeckoTerminal dex id, e.g. "uniswap-v3-robinhood"
  dexLabel: string; // humanized, e.g. "Uniswap v3"
  poolAddress: string;
  source: "geckoterminal";
  fetchedAt: number; // unix seconds when this snapshot was fetched upstream
}

/** §8 PoolSummary as the frontend consumes it + explicit pre-launch semantics. */
export interface LivePoolSummary {
  poolId: string;
  regime: "MEME" | "RWA";
  token0: TokenOut;
  token1: TokenOut;
  // ---- VAULT fields: inactive (no deployment). Explicit zeros + vaultLive:false. ----
  currentFeePips: number; // 0 — the FERA dynamic fee does not exist yet
  feeApr: number; // 0
  emissionsApr: number; // 0
  tvlUsd: number; // 0 — VAULT TVL (the pool's market TVL lives in market.tvlUsd)
  depthVsBest: number; // 0
  // ---- machine-readable honesty flag + real market block ----
  vaultLive: false;
  market: PoolMarketStats;
}

export interface LivePoolDetail extends LivePoolSummary {
  band: { fullRange: boolean };
  marketHoursState: null;
  oraclePrice: number; // 0 — no oracle wired pre-deploy
  poolPrice: number; // REAL: last observed base price on the venue
  feeHistory: never[]; // no vault fee history exists yet
  strategyLog: never[]; // no vault actions exist yet
}

export interface PriceCandle {
  t: number; // unix seconds (bucket start)
  o: number;
  h: number;
  l: number;
  c: number;
  volUsd: number;
}

// ---------------------------------------------------------------------------
// GeckoTerminal response typing (the subset we read).
// ---------------------------------------------------------------------------

interface GtToken {
  id: string;
  attributes: { address: string; symbol: string; decimals: number | null };
}
interface GtPool {
  id: string;
  attributes: {
    address: string;
    name: string;
    base_token_price_usd: string | null;
    reserve_in_usd: string | null;
    price_change_percentage?: { h24?: string | null };
    volume_usd?: { h24?: string | null };
    transactions?: { h24?: { buys?: number; sells?: number } };
  };
  relationships: {
    base_token: { data: { id: string } };
    quote_token: { data: { id: string } };
    dex: { data: { id: string } };
  };
}
interface GtPoolsResponse {
  data: GtPool[];
  included?: GtToken[];
}
interface GtOhlcvResponse {
  data: { attributes: { ohlcv_list: [number, number, number, number, number, number][] } };
}

// ---------------------------------------------------------------------------
// Tiny TTL cache with single-flight + stale-on-error.
// ---------------------------------------------------------------------------

interface Entry<T> {
  value: T;
  at: number; // ms
}
const cache = new Map<string, Entry<unknown>>();
const inflight = new Map<string, Promise<unknown>>();
const MAX_KEYS = 200;

async function cached<T>(key: string, ttlMs: number, load: () => Promise<T>): Promise<T> {
  const hit = cache.get(key) as Entry<T> | undefined;
  const now = Date.now();
  if (hit && now - hit.at < ttlMs) return hit.value;
  const running = inflight.get(key) as Promise<T> | undefined;
  if (running) return running;
  const p = load()
    .then((value) => {
      if (cache.size >= MAX_KEYS && !cache.has(key)) {
        const oldest = cache.keys().next().value;
        if (oldest !== undefined) cache.delete(oldest);
      }
      cache.set(key, { value, at: Date.now() });
      return value;
    })
    .catch((err) => {
      // Stale-on-error: an expired snapshot beats an outage (age visible via fetchedAt).
      if (hit) return hit.value;
      throw err;
    })
    .finally(() => inflight.delete(key));
  inflight.set(key, p);
  return p;
}

async function gtGet<T>(path: string): Promise<T> {
  const res = await fetch(`${GT_BASE}${path}`, {
    headers: { accept: "application/json" },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`GeckoTerminal ${res.status} @ ${path}`);
  return (await res.json()) as T;
}

// ---------------------------------------------------------------------------
// Mapping
// ---------------------------------------------------------------------------

/**
 * Regime classification is FERA's deterministic label for which vault regime WOULD run
 * this pair (MASTER_SPEC §5): RWA = tokenized equities (oracle/market-hours mechanics),
 * MEME = everything volatility-priced. It is a classification rule, not market data.
 */
const RWA_SYMBOLS = new Set(
  (process.env.FERA_RWA_SYMBOLS ?? "AAPL,NVDA,TSLA,GOOG,GOOGL,MSFT,AMZN,META,HOOD,SPY,QQQ,COIN,MSTR")
    .split(",")
    .map((s) => s.trim().toUpperCase())
    .filter(Boolean),
);

const num = (s: string | null | undefined): number => {
  const n = Number(s);
  return Number.isFinite(n) ? n : 0;
};

function dexLabel(dexId: string): string {
  const raw = dexId.replace(/-?robinhood-?/g, "").replace(/-/g, " ").trim();
  return raw
    .split(" ")
    .map((w) => (w === "v2" || w === "v3" || w === "v4" ? w : w.charAt(0).toUpperCase() + w.slice(1)))
    .join(" ") || dexId;
}

function mapPool(p: GtPool, tokens: Map<string, GtToken>, fetchedAt: number): LivePoolSummary {
  const base = tokens.get(p.relationships.base_token.data.id);
  const quote = tokens.get(p.relationships.quote_token.data.id);
  // Fallback symbols from the pool name ("CASHCAT / WETH 1%") if `included` misses one.
  const [nameBase, nameQuoteRaw] = p.attributes.name.split("/").map((s) => s.trim());
  const nameQuote = (nameQuoteRaw ?? "").split(" ")[0];
  const token0: TokenOut = {
    address: base?.attributes.address ?? "0x0000000000000000000000000000000000000000",
    symbol: base?.attributes.symbol ?? nameBase ?? "?",
    decimals: base?.attributes.decimals ?? 18,
  };
  const token1: TokenOut = {
    address: quote?.attributes.address ?? "0x0000000000000000000000000000000000000000",
    symbol: quote?.attributes.symbol ?? nameQuote ?? "?",
    decimals: quote?.attributes.decimals ?? 18,
  };
  const tx = p.attributes.transactions?.h24;
  return {
    poolId: p.attributes.address,
    regime: RWA_SYMBOLS.has(token0.symbol.toUpperCase()) ? "RWA" : "MEME",
    token0,
    token1,
    currentFeePips: 0,
    feeApr: 0,
    emissionsApr: 0,
    tvlUsd: 0,
    depthVsBest: 0,
    vaultLive: false,
    market: {
      priceUsd: num(p.attributes.base_token_price_usd),
      priceChange24h: num(p.attributes.price_change_percentage?.h24) / 100,
      volume24hUsd: num(p.attributes.volume_usd?.h24),
      tvlUsd: num(p.attributes.reserve_in_usd),
      txns24h: (tx?.buys ?? 0) + (tx?.sells ?? 0),
      dex: p.relationships.dex.data.id,
      dexLabel: dexLabel(p.relationships.dex.data.id),
      poolAddress: p.attributes.address,
      source: "geckoterminal",
      fetchedAt,
    },
  };
}

function toTokenMap(included: GtToken[] | undefined): Map<string, GtToken> {
  const m = new Map<string, GtToken>();
  for (const t of included ?? []) if (t) m.set(t.id, t);
  return m;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/** Top-N pools on the network by 24h volume — REAL, cached ~60s. */
export async function topPools(): Promise<LivePoolSummary[]> {
  return cached(`pools:${NETWORK}`, POOLS_TTL_MS, async () => {
    const fetchedAt = Math.floor(Date.now() / 1000);
    const res = await gtGet<GtPoolsResponse>(
      `/networks/${NETWORK}/pools?sort=h24_volume_usd_desc&page=1&include=base_token%2Cquote_token`,
    );
    const tokens = toTokenMap(res.included);
    return res.data.slice(0, TOP_N).map((p) => mapPool(p, tokens, fetchedAt));
  });
}

/** One pool by its venue address / v4 pool id. Falls back to a direct GT lookup so
 *  deep links beyond the top-N list still resolve. */
export async function poolByAddress(address: string): Promise<LivePoolSummary | null> {
  const fromList = (await topPools()).find(
    (p) => p.poolId.toLowerCase() === address.toLowerCase(),
  );
  if (fromList) return fromList;
  try {
    return await cached(`pool:${NETWORK}:${address.toLowerCase()}`, POOLS_TTL_MS, async () => {
      const fetchedAt = Math.floor(Date.now() / 1000);
      const res = await gtGet<{ data: GtPool; included?: GtToken[] }>(
        `/networks/${NETWORK}/pools/${encPoolId(address)}?include=base_token%2Cquote_token`,
      );
      return mapPool(res.data, toTokenMap(res.included), fetchedAt);
    });
  } catch {
    return null; // unknown pool — the route answers 404
  }
}

export function toDetail(p: LivePoolSummary): LivePoolDetail {
  return {
    ...p,
    band: { fullRange: false }, // no vault position exists — UI hides band views pre-launch
    marketHoursState: null,
    oraclePrice: 0,
    poolPrice: p.market.priceUsd, // REAL last venue price
    feeHistory: [],
    strategyLog: [],
  };
}

const TIMEFRAMES = new Set(["minute", "hour", "day"]);

/** REAL price candles for a pool (GeckoTerminal OHLCV), ascending by time. */
export async function ohlcv(
  address: string,
  timeframe = "hour",
  aggregate = 1,
  limit = 168,
): Promise<PriceCandle[]> {
  if (!TIMEFRAMES.has(timeframe)) throw new Error(`bad timeframe ${timeframe}`);
  const agg = Math.max(1, Math.min(60, Math.floor(aggregate)));
  const lim = Math.max(1, Math.min(1000, Math.floor(limit)));
  const key = `ohlcv:${NETWORK}:${address.toLowerCase()}:${timeframe}:${agg}:${lim}`;
  return cached(key, OHLCV_TTL_MS, async () => {
    const res = await gtGet<GtOhlcvResponse>(
      `/networks/${NETWORK}/pools/${encPoolId(address)}/ohlcv/${timeframe}?aggregate=${agg}&limit=${lim}`,
    );
    return res.data.attributes.ohlcv_list
      .map(([t, o, h, l, c, v]) => ({ t, o, h, l, c, volUsd: v }))
      .sort((a, b) => a.t - b.t);
  });
}
