"use client";

import { useMemo, useState } from "react";
import { useLivePools } from "@/lib/hooks/useLivePools";
import type { PoolSummary, Regime } from "@/lib/types";
import { PoolRow } from "./PoolRow";
import { Skeleton } from "@/components/ui/Skeleton";
import { ErrorState } from "@/components/ui/ErrorState";
import { Button } from "@/components/ui/Button";
import { cn } from "@/lib/cn";

type Filter = "ALL" | Regime;
const TABS: { key: Filter; label: string }[] = [
  { key: "ALL", label: "All pools" },
  { key: "MEME", label: "Meme coins" },
  { key: "RWA", label: "Stock tokens" },
];
type Sort = "tvl" | "total" | "fee";

export function PoolList() {
  // API/mock list with the deployed registry pools (config/pools.ts) enriched by LIVE
  // on-chain reads (real dynamic fee + quote NAV) — see lib/hooks/useLivePools.ts.
  const { data: pools, isLoading, error, refetch } = useLivePools();
  const [filter, setFilter] = useState<Filter>("ALL");
  const [sort, setSort] = useState<Sort>("tvl");

  // PRE-LAUNCH LIVE MODE: vaults aren't deployed (vaultLive:false from the API), so the
  // list shows REAL market columns (price / volume / market TVL) and quiet vault cells.
  // Sort keys are remapped onto the market facts; vault zeros are never sorted or shown
  // as numbers.
  const marketMode = (pools ?? []).some((p) => p.vaultLive === false);

  const rows = useMemo(() => {
    const list = (pools ?? []).filter(
      (p) => filter === "ALL" || p.regime === filter
    );
    // Chain-live rows have real USD TVL only once indexed — sort those on quote NAV.
    const tvlKey = (p: PoolSummary) =>
      p.chain?.statsPending ? p.chain.navQuote ?? 0 : p.tvlUsd;
    return [...list].sort((a, b) => {
      // The deployed on-chain pools lead the list — they're the real product.
      const liveDelta = (b.chain ? 1 : 0) - (a.chain ? 1 : 0);
      if (liveDelta !== 0) return liveDelta;
      if (marketMode && !a.chain && !b.chain) {
        const ma = a.market, mb = b.market;
        if (sort === "tvl") return (mb?.tvlUsd ?? 0) - (ma?.tvlUsd ?? 0);
        if (sort === "fee")
          return Math.abs(mb?.priceChange24h ?? 0) - Math.abs(ma?.priceChange24h ?? 0);
        return (mb?.volume24hUsd ?? 0) - (ma?.volume24hUsd ?? 0);
      }
      if (sort === "tvl") return tvlKey(b) - tvlKey(a);
      if (sort === "fee") return b.currentFeePips - a.currentFeePips;
      return b.feeApr + b.emissionsApr - (a.feeApr + a.emissionsApr);
    });
  }, [pools, filter, sort, marketMode]);

  return (
    <div className="rounded-lg border border-line bg-card shadow-card">
      {/* controls */}
      <div className="flex flex-wrap items-center justify-between gap-3 border-b border-line px-4 py-3">
        <div className="flex items-center gap-1 rounded-lg bg-well p-1">
          {TABS.map((t) => (
            <button
              key={t.key}
              onClick={() => setFilter(t.key)}
              className={cn(
                "rounded-md px-3 py-1.5 text-body-sm font-medium transition-colors",
                filter === t.key
                  ? "bg-surface text-text shadow-card"
                  : "text-mute hover:text-dim"
              )}
            >
              {t.label}
            </button>
          ))}
        </div>
        <label className="flex items-center gap-2 text-caption text-mute">
          Sort
          <select
            value={sort}
            onChange={(e) => setSort(e.target.value as Sort)}
            className="rounded-md border border-line bg-surface px-2 py-1 text-body-sm text-dim outline-none focus:border-accent-line"
          >
            <option value="tvl">{marketMode ? "Market TVL" : "TVL"}</option>
            <option value="total">{marketMode ? "24h volume" : "Total APR"}</option>
            <option value="fee">{marketMode ? "24h change" : "Live fee"}</option>
          </select>
        </label>
      </div>

      {/* header row (desktop) */}
      <div className="hidden md:grid grid-cols-[1.6fr_0.9fr_1.3fr_0.9fr_1fr_auto] gap-3 border-b border-line px-4 py-2">
        {(marketMode
          ? ["Pool", "Price · 24h", "Vault APR", "Market TVL", "24h volume", ""]
          : ["Pool", "Live fee", "APR (fee + emissions)", "TVL", "Depth vs best", ""]
        ).map((h, i) => (
          <div key={i} className="overline">
            {h}
          </div>
        ))}
      </div>

      {/* rows */}
      {isLoading ? (
        <div className="divide-y divide-line">
          {Array.from({ length: 5 }).map((_, i) => (
            <div key={i} className="flex items-center gap-4 px-4 py-4">
              <Skeleton className="h-6 w-6 rounded-full" />
              <Skeleton className="h-4 w-32" />
              <Skeleton className="ml-auto h-4 w-16" />
              <Skeleton className="h-4 w-20" />
            </div>
          ))}
        </div>
      ) : error ? (
        <ErrorState
          title="Couldn't load pools"
          message="We couldn't reach the pool data just now. Give it another try."
          onRetry={() => refetch()}
        />
      ) : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-3 px-6 py-12 text-center">
          <p className="text-body-sm text-dim">No pools in this view yet.</p>
          {filter !== "ALL" ? (
            <Button variant="secondary" size="sm" onClick={() => setFilter("ALL")}>
              Show all pools
            </Button>
          ) : null}
        </div>
      ) : (
        <div>
          {rows.map((p) => (
            <PoolRow key={p.poolId} pool={p} />
          ))}
        </div>
      )}
    </div>
  );
}
