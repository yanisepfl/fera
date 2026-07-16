"use client";

import { usePools, usePool, useDepth } from "@/lib/hooks/useApi";
import type { PoolId } from "@/lib/types";
import { LiveFeeHero } from "./LiveFeeHero";
import { Skeleton } from "@/components/ui/Skeleton";

/** Flagship pool for the Earn hero. MEME-first (PEPE/WETH); tokenized stocks soon. */
const FEATURED: PoolId =
  "0x0000000000000000000000000000000000000000000000000000000000000002";

export function FeaturedHero() {
  const { data: pools } = usePools();
  // Live mode serves REAL pool ids, so the fixture FEATURED id won't match — fall back
  // to the top pool and query detail/depth for the pool we actually render.
  const pool = pools?.find((p) => p.poolId === FEATURED) ?? pools?.[0];
  const { data: detail } = usePool(pool?.poolId);
  const { data: depth } = useDepth(pool?.poolId);

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
