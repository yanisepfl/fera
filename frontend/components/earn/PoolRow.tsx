"use client";

import Link from "next/link";
import type { PoolSummary } from "@/lib/types";
import { RegimeBadge } from "@/components/ui/Badge";
import { TokenPair } from "@/components/ui/TokenPair";
import { LiveFee } from "./LiveFee";
import { DepositDialog } from "./DepositDialog";
import { Button } from "@/components/ui/Button";
import { apr, usdCompact, multiple } from "@/lib/format";

/** One pool in the Earn list. Fee is LIVE; APY is split into fee-yield vs emissions. */
export function PoolRow({ pool }: { pool: PoolSummary }) {
  return (
    <div className="group grid grid-cols-2 items-center gap-3 border-b border-line px-4 py-3.5 last:border-0 hover:bg-elevated md:grid-cols-[1.6fr_0.9fr_1.3fr_0.9fr_1fr_auto]">
      {/* pair + regime */}
      <Link
        href={`/app/pool/${pool.poolId}`}
        className="flex items-center gap-3 min-w-0"
      >
        <TokenPair token0={pool.token0} token1={pool.token1} />
        <RegimeBadge regime={pool.regime} className="hidden sm:inline-flex" />
      </Link>

      {/* live fee */}
      <div className="text-right md:text-left">
        <div className="overline mb-0.5 md:hidden">Live fee</div>
        <LiveFee seedPips={pool.currentFeePips} regime={pool.regime} />
      </div>

      {/* APY split */}
      <div className="col-span-2 flex items-center gap-4 md:col-span-1">
        <div>
          <div className="overline mb-0.5">Fee APR</div>
          <div className="font-mono tnum text-body font-semibold text-pos">
            {apr(pool.feeApr)}
          </div>
        </div>
        <div className="text-mute">+</div>
        <div>
          <div className="overline mb-0.5">Emissions</div>
          <div className="font-mono tnum text-body font-semibold text-accent">
            {apr(pool.emissionsApr)}
          </div>
        </div>
      </div>

      {/* TVL */}
      <div className="hidden md:block">
        <div className="overline mb-0.5">TVL</div>
        <div className="font-mono tnum text-body text-text">
          {usdCompact(pool.tvlUsd)}
        </div>
      </div>

      {/* depth vs best */}
      <div className="hidden md:block">
        <div className="overline mb-0.5">Depth vs best</div>
        <div className="font-mono tnum text-body text-text">
          {multiple(pool.depthVsBest)}
          <span className="ml-1 text-caption text-pos">deeper</span>
        </div>
      </div>

      {/* deposit */}
      <div className="col-span-2 md:col-span-1 md:justify-self-end">
        <DepositDialog
          pool={pool}
          trigger={(open) => (
            <Button
              size="sm"
              variant="secondary"
              onClick={open}
              className="w-full md:w-auto group-hover:border-accent-line"
            >
              Deposit
            </Button>
          )}
        />
      </div>
    </div>
  );
}
