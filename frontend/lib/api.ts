/**
 * FERA typed API client — the ONLY surface through which the UI reads pool
 * lists / aggregates (MASTER_SPEC §6/§8: never read the chain directly for these).
 *
 * Source resolution:
 *   1. NEXT_PUBLIC_API_URL set  → fetch Backend (4)'s indexer/API (real §8 JSON).
 *   2. NEXT_PUBLIC_USE_MSW=1     → fetch same-origin /api/* intercepted by MSW.
 *   3. otherwise                 → resolve straight from mocks/fixtures.ts
 *      (zero network — works in `next build`, RSC, and CI without a running backend).
 *
 * Every function's return type is imported from lib/types.ts, which mirrors §8
 * field names verbatim. Swap the source; the types don't move.
 */
import type {
  PoolSummary,
  PoolDetail,
  DepthComparison,
  Position,
  CurrentEpoch,
  ClaimProof,
  StakingSummary,
  VestingGrant,
  EmissionsTransparency,
  RevenueTransparency,
  Address,
  PoolId,
} from "./types";
import * as fx from "@/mocks/fixtures";

const API_URL = process.env.NEXT_PUBLIC_API_URL?.replace(/\/$/, "") ?? "";
const USE_MSW = process.env.NEXT_PUBLIC_USE_MSW === "1";
// When we have neither a real API nor MSW, serve fixtures directly.
const LOCAL = !API_URL && !USE_MSW;
// MSW intercepts same-origin /api. Real API uses its own base.
const BASE = API_URL || "/api";

async function get<T>(path: string, localValue: () => T): Promise<T> {
  if (LOCAL) {
    // Simulate the read-through cache latency so loading states are exercised.
    await new Promise((r) => setTimeout(r, 30));
    return localValue();
  }
  const res = await fetch(`${BASE}${path}`, {
    headers: { accept: "application/json" },
    // live dynamic fee is read-through cached TTL ≤ ~1s (§8)
    cache: "no-store",
  });
  if (!res.ok) throw new ApiError(res.status, path);
  return (await res.json()) as T;
}

export class ApiError extends Error {
  constructor(public status: number, public path: string) {
    super(`FERA API ${status} @ ${path}`);
    this.name = "ApiError";
  }
}

// ---- §8 endpoints -----------------------------------------------------------

export const api = {
  /** GET /pools */
  pools: () => get<PoolSummary[]>("/pools", () => fx.POOLS),

  /** GET /pools/:poolId */
  pool: (poolId: PoolId) =>
    get<PoolDetail>(`/pools/${poolId}`, () => {
      const d = fx.POOL_DETAILS[poolId];
      if (!d) throw new ApiError(404, `/pools/${poolId}`);
      return d;
    }),

  /** GET /pools/:poolId/depth */
  depth: (poolId: PoolId) =>
    get<DepthComparison>(`/pools/${poolId}/depth`, () => {
      const d = fx.DEPTH[poolId];
      if (!d) throw new ApiError(404, `/pools/${poolId}/depth`);
      return d;
    }),

  /** GET /positions/:account */
  positions: (account: Address) =>
    get<Position[]>(`/positions/${account}`, () => fx.POSITIONS),

  /** GET /epochs/current */
  currentEpoch: () =>
    get<CurrentEpoch>("/epochs/current", () => fx.CURRENT_EPOCH),

  /** GET /epochs/:id/proof/:account */
  claimProof: (epochId: number, account: Address) =>
    get<ClaimProof>(`/epochs/${epochId}/proof/${account}`, () => fx.CLAIM_PROOF),

  /** GET /staking/:account */
  staking: (account: Address) =>
    get<StakingSummary>(`/staking/${account}`, () => fx.STAKING),

  /** GET /vesting/:account (added v0.2, OD-6/FE-6) — esFERA grants, string amounts. */
  vesting: (account: Address) =>
    get<VestingGrant[]>(`/vesting/${account}`, () => fx.VESTING),

  /** GET /transparency/emissions */
  emissions: () =>
    get<EmissionsTransparency>("/transparency/emissions", () => fx.EMISSIONS),

  /** GET /transparency/revenue */
  revenue: () =>
    get<RevenueTransparency>("/transparency/revenue", () => fx.REVENUE),
};

export type Api = typeof api;
