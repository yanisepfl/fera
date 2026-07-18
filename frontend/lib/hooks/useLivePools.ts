"use client";

import { useCallback, useMemo } from "react";
import { useReadContracts } from "wagmi";
import { formatUnits } from "viem";
import { usePools, usePool } from "./useApi";
import { activeChain } from "@/config/chains";
import {
  LIVE_POOLS,
  VAULT,
  HOOK,
  livePoolById,
  poolTokenPair,
  type LivePool,
} from "@/config/pools";
import { feraVaultAbi } from "@/lib/abi/feraVault";
import { feraHookAbi } from "@/lib/abi/feraHook";
import type {
  ChainLiveOverlay,
  PoolDetail,
  PoolId,
  PoolSummary,
} from "@/lib/types";

/**
 * LIVE on-chain reads for the deployed registry pools (config/pools.ts), merged over
 * the API/mock pool list — so the 5 REAL pools render REAL numbers (dynamic fee from
 * FeraHook.getDynamicFee, tranche-0 NAV from FeraVault.quoteNav) even before the
 * indexer backend is deployed.
 *
 * Merge rules (honesty first — never invent a number):
 *  - a registry pool only appears once its chain reads actually landed;
 *  - if the API already knows the pool WITH vault data, the API row wins and the chain
 *    values just overlay fee/NAV (`chain.statsPending = false`);
 *  - if the API only has a pre-launch market row for the same pair (GeckoTerminal rows
 *    are keyed by VENUE address, not v4 PoolId — matched by symbol), its REAL market
 *    stats are carried over and the row is absorbed (no duplicate listing);
 *  - indexer-derived fields we cannot read cheaply on-chain (APRs, USD TVL, depth,
 *    volume) stay unknown → `chain.statsPending = true` and the UI renders "—".
 */

const CHAIN_ID = activeChain.id;
const CALLS_PER_POOL = 3;

const CHAIN_CONTRACTS = LIVE_POOLS.flatMap((p) => [
  { address: VAULT, abi: feraVaultAbi, functionName: "quoteNav", args: [p.poolId, 0], chainId: CHAIN_ID },
  { address: HOOK, abi: feraHookAbi, functionName: "getDynamicFee", args: [p.poolId], chainId: CHAIN_ID },
  { address: VAULT, abi: feraVaultAbi, functionName: "depositsPaused", args: [p.poolId], chainId: CHAIN_ID },
] as const);

interface PoolChainState {
  navQuoteWei?: bigint;
  feePips?: number;
  depositsPaused?: boolean;
  /** at least one read landed — the vault is verifiably reachable for this pool. */
  reachable: boolean;
}

function pick<T>(
  data: readonly { status: string; result?: unknown }[] | undefined,
  i: number,
): T | undefined {
  const r = data?.[i];
  return r && r.status === "success" ? (r.result as T) : undefined;
}

/**
 * One shared multicall over all registry pools (batched through Multicall3 on 4663).
 * ~8s polling: the fee is the number we present as live; the chain soft-blocks at
 * ~100ms but the public RPC is rate-limited, so we stay gentle.
 */
export function useLivePoolChain() {
  const res = useReadContracts({
    allowFailure: true,
    contracts: CHAIN_CONTRACTS,
    query: { refetchInterval: 8_000, staleTime: 4_000 },
  });

  const byId = useMemo(() => {
    const m = new Map<string, PoolChainState>();
    LIVE_POOLS.forEach((p, i) => {
      const navQuoteWei = pick<bigint>(res.data, i * CALLS_PER_POOL);
      const fee = pick<number>(res.data, i * CALLS_PER_POOL + 1);
      const depositsPaused = pick<boolean>(res.data, i * CALLS_PER_POOL + 2);
      m.set(p.poolId.toLowerCase(), {
        navQuoteWei,
        feePips: fee !== undefined ? Number(fee) : undefined,
        depositsPaused,
        reachable: navQuoteWei !== undefined || fee !== undefined,
      });
    });
    return m;
  }, [res.data]);

  return { ...res, byId };
}

function overlayOf(reg: LivePool, st: PoolChainState, statsPending: boolean): ChainLiveOverlay {
  return {
    feeLive: st.feePips !== undefined,
    navQuote:
      st.navQuoteWei !== undefined
        ? Number(formatUnits(st.navQuoteWei, reg.quoteDecimals))
        : undefined,
    quoteSymbol: reg.quoteSymbol,
    statsPending,
    depositsPaused: st.depositsPaused,
  };
}

/** API row carries indexed VAULT data (not just market facts)? Then it stays the base. */
const isIndexed = (p: PoolSummary | undefined): p is PoolSummary =>
  p !== undefined && p.vaultLive !== false;

/** Overlay live chain values on an indexed API row (API keeps APRs/TVL/etc). */
function overlayIndexed<T extends PoolSummary>(base: T, reg: LivePool, st: PoolChainState): T {
  return {
    ...base,
    currentFeePips: st.feePips ?? base.currentFeePips,
    vaultLive: true,
    chain: overlayOf(reg, st, false),
  };
}

/** Build a row purely from the registry + chain (+ optional REAL market stats). */
function synthesize(reg: LivePool, st: PoolChainState, marketRow?: PoolSummary): PoolSummary {
  const { token0, token1 } = poolTokenPair(reg);
  return {
    poolId: reg.poolId,
    regime: "MEME",
    token0,
    token1,
    currentFeePips: st.feePips ?? 0,
    // Unknown until the indexer ships — chain.statsPending makes the UI say "—", not 0.
    feeApr: 0,
    emissionsApr: 0,
    tvlUsd: 0,
    depthVsBest: 0,
    vaultLive: true,
    market: marketRow?.market,
    chain: overlayOf(reg, st, true),
  };
}

/** wWETH-vs-WETH tolerant symbol equality for absorbing venue market rows. */
function quoteSymEq(a: string, b: string): boolean {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  if (x === y) return true;
  const eth = new Set(["weth", "wweth"]);
  return eth.has(x) && eth.has(y);
}

function matchMarketRow(reg: LivePool, pools: PoolSummary[] | undefined): PoolSummary | undefined {
  if (!pools) return undefined;
  const meme = reg.symbol.toLowerCase();
  return pools.find(
    (p) =>
      p.vaultLive === false &&
      ((p.token0.symbol.toLowerCase() === meme && quoteSymEq(p.token1.symbol, reg.quoteSymbol)) ||
        (p.token1.symbol.toLowerCase() === meme && quoteSymEq(p.token0.symbol, reg.quoteSymbol))),
  );
}

/**
 * Drop-in upgrade over useApi#usePools: same `{ data, isLoading, error, refetch }`
 * surface, with the registry pools enriched from chain and sorted first.
 */
export function useLivePools() {
  const api = usePools();
  const chain = useLivePoolChain();

  const data = useMemo(() => {
    const apiPools = api.data;
    const absorbed = new Set<string>();
    const liveRows: PoolSummary[] = [];

    for (const reg of LIVE_POOLS) {
      const st = chain.byId.get(reg.poolId.toLowerCase());
      if (!st?.reachable) continue; // nothing REAL to show for this pool
      const direct = apiPools?.find(
        (p) => p.poolId.toLowerCase() === reg.poolId.toLowerCase(),
      );
      if (direct) absorbed.add(direct.poolId.toLowerCase());
      if (isIndexed(direct)) {
        liveRows.push(overlayIndexed(direct, reg, st));
        continue;
      }
      const marketRow = direct ?? matchMarketRow(reg, apiPools);
      if (marketRow) absorbed.add(marketRow.poolId.toLowerCase());
      liveRows.push(synthesize(reg, st, marketRow));
    }

    // The real product leads the list; inside the group, deepest NAV first.
    liveRows.sort((a, b) => (b.chain?.navQuote ?? 0) - (a.chain?.navQuote ?? 0));
    const rest = (apiPools ?? []).filter((p) => !absorbed.has(p.poolId.toLowerCase()));
    if (!liveRows.length && !apiPools) return undefined;
    return [...liveRows, ...rest];
  }, [api.data, chain.byId]);

  const refetch = useCallback(() => {
    api.refetch();
    chain.refetch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [api.refetch, chain.refetch]);

  return {
    data,
    isLoading: !data && api.isLoading,
    // API trouble is invisible while we still have real rows to show.
    error: data && data.length ? null : api.error,
    refetch,
  };
}

/**
 * Drop-in upgrade over useApi#usePool for the pool page. For registry pools it
 * overlays live chain values; if the API doesn't know the pool at all (fixture mode,
 * or pre-indexer), it synthesizes an honest minimal PoolDetail (empty history/log —
 * the page renders those as "indexing", never as fabricated series).
 */
export function useLivePool(poolId?: PoolId) {
  const api = usePool(poolId);
  const chain = useLivePoolChain();
  const reg = livePoolById(poolId);

  const data = useMemo<PoolDetail | undefined>(() => {
    if (!reg) return api.data;
    const st = chain.byId.get(reg.poolId.toLowerCase());
    if (!st?.reachable) return api.data;
    if (isIndexed(api.data)) return overlayIndexed(api.data, reg, st);
    return {
      ...synthesize(reg, st, api.data),
      band: { fullRange: true },
      marketHoursState: null,
      oraclePrice: 0,
      poolPrice: 0,
      feeHistory: [],
      strategyLog: [],
    };
  }, [reg, api.data, chain.byId]);

  const refetch = useCallback(() => {
    api.refetch();
    chain.refetch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [api.refetch, chain.refetch]);

  return {
    data,
    isLoading: !data && (api.isLoading || chain.isLoading),
    error: data ? null : api.error,
    refetch,
  };
}
