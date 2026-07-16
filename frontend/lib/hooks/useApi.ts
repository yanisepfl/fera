"use client";

import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import type { Address, PoolId } from "@/lib/types";

/**
 * React Query hooks over the §8 client. Keys are stable so wagmi's shared
 * QueryClient can dedupe/refetch. Live-ish views use a short refetchInterval to
 * mirror the read-through cache; static transparency views don't.
 */

export const usePools = () =>
  useQuery({ queryKey: ["pools"], queryFn: api.pools, refetchInterval: 15_000 });

export const usePool = (poolId?: PoolId) =>
  useQuery({
    queryKey: ["pool", poolId],
    queryFn: () => api.pool(poolId!),
    enabled: !!poolId,
    refetchInterval: 15_000,
  });

export const useDepth = (poolId?: PoolId) =>
  useQuery({
    queryKey: ["depth", poolId],
    queryFn: () => api.depth(poolId!),
    enabled: !!poolId,
  });

/** REAL venue price candles (pre-launch live mode); ~60s server cache upstream. */
export const useCandles = (poolId?: PoolId) =>
  useQuery({
    queryKey: ["candles", poolId],
    queryFn: () => api.candles(poolId!),
    enabled: !!poolId,
    refetchInterval: 60_000,
  });

export const usePositions = (account?: Address) =>
  useQuery({
    queryKey: ["positions", account],
    queryFn: () => api.positions(account!),
    enabled: !!account,
  });

export const useCurrentEpoch = () =>
  useQuery({ queryKey: ["epoch", "current"], queryFn: api.currentEpoch });

export const useClaimProof = (epochId?: number, account?: Address) =>
  useQuery({
    queryKey: ["claimProof", epochId, account],
    queryFn: () => api.claimProof(epochId!, account!),
    enabled: epochId !== undefined && !!account,
  });

export const useStaking = (account?: Address) =>
  useQuery({
    queryKey: ["staking", account],
    queryFn: () => api.staking(account!),
    enabled: !!account,
  });

export const useVesting = (account?: Address) =>
  useQuery({
    queryKey: ["vesting", account],
    queryFn: () => api.vesting(account!),
    enabled: !!account,
  });

export const useEmissions = () =>
  useQuery({ queryKey: ["transparency", "emissions"], queryFn: api.emissions });

export const useRevenue = () =>
  useQuery({ queryKey: ["transparency", "revenue"], queryFn: api.revenue });
