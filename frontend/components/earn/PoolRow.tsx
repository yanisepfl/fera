"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import type { PoolSummary } from "@/lib/types";
import { RegimeBadge } from "@/components/ui/Badge";
import { TokenPair } from "@/components/ui/TokenPair";
import { LiveFee } from "./LiveFee";
import { DepositDialog } from "./DepositDialog";
import { Button } from "@/components/ui/Button";
import { apr, usdCompact, usdPrice, signedPct, multiple } from "@/lib/format";

/**
 * One pool in the Earn list. Fee is LIVE; APY is split into fee-yield vs emissions.
 *
 * Clicking ANYWHERE on the row opens the deposit dialog with this pool preselected -
 * the row IS the deposit action (a list click should lead to doing, not to a detail
 * page). The per-pool page is demoted to the small "Details" link, which stops
 * propagation so it never also opens the dialog.
 *
 * PRE-LAUNCH LIVE MODE (`vaultLive === false`): the vault doesn't exist yet, so vault
 * numbers (fee, APRs, vault TVL, depth) must NOT render as numbers. The row instead
 * shows the REAL market facts for the underlying venue (price, 24h change, 24h volume,
 * pool TVL) and a quiet "Opens at launch" where the vault economics will live. The row
 * click navigates to the pool page (there is nothing to deposit into yet).
 */
export function PoolRow({ pool }: { pool: PoolSummary }) {
  if (pool.vaultLive === false) return <MarketPoolRow pool={pool} />;
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

/** Pre-launch row: REAL market data, honest quiet vault cells. */
function MarketPoolRow({ pool }: { pool: PoolSummary }) {
  const router = useRouter();
  const m = pool.market;
  const chg = m?.priceChange24h ?? 0;
  const chgColor = chg >= 0 ? "text-pos" : "text-neg";
  const href = `/app/pool/${pool.poolId}`;

  return (
    <div
      role="link"
      tabIndex={0}
      aria-label={`${pool.token0.symbol}/${pool.token1.symbol} market details`}
      onClick={() => router.push(href)}
      onKeyDown={(e) => {
        if (e.target !== e.currentTarget) return;
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          router.push(href);
        }
      }}
      className="group grid cursor-pointer grid-cols-2 items-center gap-3 border-b border-line px-4 py-3.5 last:border-0 hover:bg-elevated md:grid-cols-[1.6fr_0.9fr_1.3fr_0.9fr_1fr_auto]"
    >
      {/* pair + regime */}
      <div className="flex min-w-0 items-center gap-3">
        <TokenPair token0={pool.token0} token1={pool.token1} />
        <RegimeBadge regime={pool.regime} className="hidden sm:inline-flex" />
      </div>

      {/* price + 24h change — REAL */}
      <div className="text-right md:text-left">
        <div className="overline mb-0.5 md:hidden">Price</div>
        <div className="font-mono tnum text-body font-semibold text-text">
          {m ? usdPrice(m.priceUsd) : "—"}
        </div>
        {m ? (
          <div className={`font-mono tnum text-caption ${chgColor}`}>
            {signedPct(chg, 1)} 24h
          </div>
        ) : null}
      </div>

      {/* vault APR — inactive, honest */}
      <div className="col-span-2 flex items-baseline gap-2 md:col-span-1">
        <span className="font-mono tnum text-body font-semibold text-mute">—</span>
        <span className="text-caption text-mute">vault APR opens at launch</span>
      </div>

      {/* market TVL — REAL (the venue pool, not the vault) */}
      <div className="hidden md:block">
        <div className="overline mb-0.5 md:hidden">Market TVL</div>
        <div className="font-mono tnum text-body text-text">
          {m ? usdCompact(m.tvlUsd) : "—"}
        </div>
      </div>

      {/* 24h volume — REAL */}
      <div className="hidden md:block">
        <div className="overline mb-0.5 md:hidden">24h volume</div>
        <div className="font-mono tnum text-body text-text">
          {m ? usdCompact(m.volume24hUsd) : "—"}
        </div>
      </div>

      {/* details only — there is no deposit yet */}
      <div className="col-span-2 flex items-center justify-end gap-3 md:col-span-1 md:justify-self-end">
        <span className="hidden rounded-full border border-line bg-well px-2 py-0.5 text-caption text-mute sm:inline">
          Opens at launch
        </span>
        <Link
          href={href}
          onClick={(e) => e.stopPropagation()}
          className="shrink-0 text-caption font-medium text-mute transition-colors hover:text-dim"
        >
          Details <span aria-hidden>&rarr;</span>
        </Link>
      </div>
    </div>
  );
}
