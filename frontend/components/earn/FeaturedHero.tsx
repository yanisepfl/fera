"use client";

import { usePools, usePool, useDepth } from "@/lib/hooks/useApi";
import type { PoolId } from "@/lib/types";
import { LiveFeeHero } from "./LiveFeeHero";
import { Skeleton } from "@/components/ui/Skeleton";

/** Flagship pool for the Earn hero (NVDA/USDG, the depth showcase). */
const FEATURED: PoolId =
  "0x0000000000000000000000000000000000000000000000000000000000000001";

export function FeaturedHero() {
  const { data: pools } = usePools();
  const { data: detail } = usePool(FEATURED);
  const { data: depth } = useDepth(FEATURED);

  const pool = pools?.find((p) => p.poolId === FEATURED) ?? pools?.[0];
  if (!pool) return <Skeleton className="h-64 w-full rounded-lg" />;

  // "deepest NVDA/USDG pool" when FERA leads the depth table.
  let depthLabel = "deeper than best venue";
  if (depth) {
    const top = [...depth.venues].sort((a, b) => b.depthUsd - a.depthUsd)[0];
    if (top?.isFera) depthLabel = `deepest ${depth.pair} pool`;
  }

  return (
    <LiveFeeHero
      pool={pool}
      marketState={detail?.marketHoursState}
      depthLabel={depthLabel}
    />
  );
}
