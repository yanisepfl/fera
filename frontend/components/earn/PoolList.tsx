"use client";

import { useMemo, useState } from "react";
import { usePools } from "@/lib/hooks/useApi";
import type { Regime } from "@/lib/types";
import { PoolRow } from "./PoolRow";
import { Skeleton } from "@/components/ui/Skeleton";
import { cn } from "@/lib/cn";

type Filter = "ALL" | Regime;
const TABS: { key: Filter; label: string }[] = [
  { key: "ALL", label: "All pools" },
  { key: "RWA", label: "RWA" },
  { key: "MEME", label: "MEME" },
];
type Sort = "tvl" | "total" | "fee";

export function PoolList() {
  const { data: pools, isLoading, error } = usePools();
  const [filter, setFilter] = useState<Filter>("ALL");
  const [sort, setSort] = useState<Sort>("tvl");

  const rows = useMemo(() => {
    const list = (pools ?? []).filter(
      (p) => filter === "ALL" || p.regime === filter
    );
    return [...list].sort((a, b) => {
      if (sort === "tvl") return b.tvlUsd - a.tvlUsd;
      if (sort === "fee") return b.currentFeePips - a.currentFeePips;
      return b.feeApr + b.emissionsApr - (a.feeApr + a.emissionsApr);
    });
  }, [pools, filter, sort]);

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
            <option value="tvl">TVL</option>
            <option value="total">Total APR</option>
            <option value="fee">Live fee</option>
          </select>
        </label>
      </div>

      {/* header row (desktop) */}
      <div className="hidden md:grid grid-cols-[1.6fr_0.9fr_1.3fr_0.9fr_1fr_auto] gap-3 border-b border-line px-4 py-2">
        {["Pool", "Live fee", "APR (fee + emissions)", "TVL", "Depth vs best", ""].map(
          (h, i) => (
            <div key={i} className="overline">
              {h}
            </div>
          )
        )}
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
        <div className="px-4 py-10 text-center text-body-sm text-neg">
          Failed to load pools. {(error as Error).message}
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
