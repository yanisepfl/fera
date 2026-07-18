"use client";

import { usePool, useDepth } from "@/lib/hooks/useApi";
import { useLivePools } from "@/lib/hooks/useLivePools";
import type { PoolId } from "@/lib/types";
import { LiveFeeHero } from "./LiveFeeHero";
import { Skeleton } from "@/components/ui/Skeleton";

/** Flagship pool for the Earn hero. MEME-first (PEPE/WETH); tokenized stocks soon. */
const FEATURED: PoolId =
  "0x0000000000000000000000000000000000000000000000000000000000000002";

export function FeaturedHero() {
  // Chain-live registry pools lead the merged list — when one exists, the hero
  // features the REAL deployed product (real fee, real NAV), not a fixture.
  const { data: pools } = useLivePools();
  const pool =
    pools?.find((p) => p.chain) ??
    pools?.find((p) => p.poolId === FEATURED) ??
    pools?.[0];
  const { data: detail } = usePool(pool?.poolId);
  const { data: depth } = useDepth(pool?.poolId);

  if (!pool) return <Skeleton className="h-64 w-full rounded-lg" />;

  // "deepest NVDA/USDG pool" when FERA leads the depth table. (venues is guarded —
  // the Ponder backend's depth shape differs and may omit it; see the §8 mismatch log.)
  let depthLabel = "deeper than best venue";
  if (depth?.venues?.length) {
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
