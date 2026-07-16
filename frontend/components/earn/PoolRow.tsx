"use client";

import Link from "next/link";
import type { PoolSummary } from "@/lib/types";
import { RegimeBadge } from "@/components/ui/Badge";
import { TokenPair } from "@/components/ui/TokenPair";
import { LiveFee } from "./LiveFee";
import { DepositDialog } from "./DepositDialog";
import { Button } from "@/components/ui/Button";
import { apr, usdCompact, multiple } from "@/lib/format";

/**
 * One pool in the Earn list. Fee is LIVE; APY is split into fee-yield vs emissions.
 *
 * Clicking ANYWHERE on the row opens the deposit dialog with this pool preselected -
 * the row IS the deposit action (a list click should lead to doing, not to a detail
 * page). The per-pool page is demoted to the small "Details" link, which stops
 * propagation so it never also opens the dialog.
 */
export function PoolRow({ pool }: { pool: PoolSummary }) {
  return (
    <DepositDialog
      pool={pool}
      trigger={(open) => (
        <div
          role="button"
          tabIndex={0}
          aria-label={`Deposit into ${pool.token0.symbol}/${pool.token1.symbol}`}
          onClick={open}
          onKeyDown={(e) => {
            // Only the row itself: Enter/Space on the nested link/button bubble here too.
            if (e.target !== e.currentTarget) return;
            if (e.key === "Enter" || e.key === " ") {
              e.preventDefault();
              open();
            }
          }}
          className="group grid cursor-pointer grid-cols-2 items-center gap-3 border-b border-line px-4 py-3.5 last:border-0 hover:bg-elevated md:grid-cols-[1.6fr_0.9fr_1.3fr_0.9fr_1fr_auto]"
        >
          {/* pair + regime */}
          <div className="flex min-w-0 items-center gap-3">
            <TokenPair token0={pool.token0} token1={pool.token1} />
            <RegimeBadge regime={pool.regime} className="hidden sm:inline-flex" />
          </div>

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

          {/* deposit (primary) + details (secondary) */}
          <div className="col-span-2 flex items-center gap-3 md:col-span-1 md:justify-self-end">
            <Button
              size="sm"
              variant="secondary"
              onClick={(e) => {
                e.stopPropagation();
                open();
              }}
              className="flex-1 group-hover:border-accent2-line md:flex-none"
            >
              Deposit
            </Button>
            <Link
              href={`/app/pool/${pool.poolId}`}
              onClick={(e) => e.stopPropagation()}
              className="shrink-0 text-caption font-medium text-mute transition-colors hover:text-dim"
            >
              Details <span aria-hidden>&rarr;</span>
            </Link>
          </div>
        </div>
      )}
    />
  );
}
