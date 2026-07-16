/**
 * MSW request handlers - realistic same-origin /api/* interceptors that return the
 * §8 shapes from fixtures. Enabled with NEXT_PUBLIC_USE_MSW=1 (browser) or in
 * Playwright/node. Default dev path uses fixtures directly via lib/api.ts, so MSW is
 * an opt-in "closer to the wire" mode (adds latency, exercises fetch/error paths).
 */
import { http, HttpResponse, delay } from "msw";
import * as fx from "./fixtures";

const j = <T>(data: T, ms = 60) =>
  (async () => {
    await delay(ms);
    // fixtures are plain JSON-serializable objects/arrays; cast to satisfy MSW's JsonBodyType
    return HttpResponse.json(data as unknown as Record<string, unknown>);
  })();

export const handlers = [
  http.get("/api/pools", () => j(fx.POOLS)),

  // Real-market candle series exists only in live mode (vaultLive:false pools);
  // fixtures model deployed vaults, so mocks serve an EMPTY series (the price-history
  // card simply doesn't render) - never a fabricated one.
  http.get("/api/pools/:poolId/ohlcv", () => j([])),

  http.get("/api/pools/:poolId/depth", ({ params }) => {
    const d = fx.DEPTH[String(params.poolId)];
    return d ? j(d) : new HttpResponse(null, { status: 404 });
  }),

  http.get("/api/pools/:poolId", ({ params }) => {
    const d = fx.POOL_DETAILS[String(params.poolId)];
    return d ? j(d) : new HttpResponse(null, { status: 404 });
  }),

  http.get("/api/positions/:account", () => j(fx.POSITIONS)),

  http.get("/api/epochs/current", () => j(fx.CURRENT_EPOCH)),

  http.get("/api/epochs/:id/proof/:account", () => j(fx.CLAIM_PROOF)),

  http.get("/api/staking/:account", () => j(fx.STAKING)),

  http.get("/api/vesting/:account", () => j(fx.VESTING)),

  http.get("/api/transparency/emissions", () => j(fx.EMISSIONS)),

  http.get("/api/transparency/revenue", () => j(fx.REVENUE)),
];
