"use client";

import Link from "next/link";
import { useState } from "react";
import type { PoolId, RiskClass } from "@/lib/types";
import { useLivePool } from "@/lib/hooks/useLivePools";
import { RegimeBadge } from "@/components/ui/Badge";
import { LiveFee } from "@/components/earn/LiveFee";
import { LiveDot } from "@/components/ui/LiveDot";
import { Stat } from "@/components/ui/Stat";
import { Skeleton } from "@/components/ui/Skeleton";
import { Card, CardHeader } from "@/components/ui/Card";
import { ErrorState } from "@/components/ui/ErrorState";
import { MemeExplainer } from "./MemeExplainer";
import { BandLadder } from "./BandLadder";
import { OracleBand } from "./OracleBand";
import { FeeHistory } from "./FeeHistory";
import { PriceHistory } from "./PriceHistory";
import { StrategyLog } from "./StrategyLog";
import { YourPosition } from "./YourPosition";
import { RiskClassSelector } from "./RiskClassSelector";
import { OpenLiquidityNote } from "./OpenLiquidityNote";
import { apr, usdCompact, usdPrice, signedPct, multiple, tokenAmt } from "@/lib/format";

export function PoolDetailView({ poolId }: { poolId: PoolId }) {
  // Registry pools (config/pools.ts) come enriched with LIVE on-chain fee/NAV — and
  // render even when the API doesn't know the pool yet (pre-indexer).
  const { data: pool, isLoading, error, refetch } = useLivePool(poolId);
  const [riskClass, setRiskClass] = useState<RiskClass>("CORE");

  if (isLoading) return <Skeleton className="h-96 w-full rounded-lg" />;
  if (error || !pool)
    return (
      <Card className="mx-auto max-w-md">
        <ErrorState
          title="We couldn't load this pool"
          message="It may not exist, or the data was briefly unreachable."
          onRetry={() => refetch()}
        />
        <div className="border-t border-line px-6 py-4 text-center">
          <Link href="/app" className="text-body-sm font-medium text-accent hover:text-accent-strong">
            &larr; Back to Earn
          </Link>
        </div>
      </Card>
    );

  // PRE-LAUNCH LIVE MODE: market facts are REAL (price/volume/TVL of the venue pool);
  // every vault surface (fee, APRs, bands, strategy log, fee history) doesn't exist yet
  // and renders as an honest "opens at launch" — never as a number or an empty chart.
  const vaultLive = pool.vaultLive !== false;
  const m = pool.market;
  const chg = m?.priceChange24h ?? 0;
  // ON-CHAIN LIVE MODE: fee/NAV are read from the deployed contracts; indexer-derived
  // stats (APRs, USD TVL, depth, history) aren't served yet → "—" / "indexing", never 0.
  const chain = pool.chain;
  const statsPending = chain?.statsPending === true;

  return (
    <div className="space-y-6">
      {/* header - marketing-style heading treatment (green eyebrow + display title) */}
      <div className="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
        <div className="min-w-0 max-w-2xl">
          <Link href="/app" className="text-body-sm text-mute hover:text-dim">
            ← Earn
          </Link>
          <div className="overline overline-gold mb-2 mt-3">Pool</div>
          <div className="flex flex-wrap items-center gap-3">
            <h1 className="text-display-l font-semibold tracking-tight text-text">
              {pool.token0.symbol}
              <span className="text-mute"> / </span>
              {pool.token1.symbol}
            </h1>
            <RegimeBadge regime={pool.regime} />
          </div>
          <p className="mt-2 text-body text-dim">
            {vaultLive ? (
              <>
                The vault runs this market around the clock. Every swap pays the
                people in it.
              </>
            ) : (
              <>
                Live market on Robinhood Chain{m ? ` (${m.dexLabel})` : ""}. The FERA
                vault for it opens at launch — market numbers below are real.
              </>
            )}
          </p>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {vaultLive ? (
            <>
              <LiveDot label="LIVE FEE" />
              <LiveFee
                seedPips={pool.currentFeePips}
                regime={pool.regime}
                simulate={!chain?.feeLive}
              />
            </>
          ) : (
            <>
              <LiveDot label="LIVE MARKET" color="var(--accent2)" />
              <span className="font-mono tnum text-body font-semibold text-text">
                {m ? usdPrice(m.priceUsd) : "—"}
              </span>
            </>
          )}
        </div>
      </div>

      {/* headline stats */}
      <Card>
        <div className="grid grid-cols-2 gap-5 p-5 sm:grid-cols-4">
          {vaultLive ? (
            <>
              <Stat
                label="Fee-yield APR"
                value={statsPending ? "—" : apr(pool.feeApr)}
                accent={statsPending ? undefined : "var(--pos)"}
                sub={statsPending ? "arrives with the indexer" : undefined}
                tip="The trading fees this position has been earning, shown after fees."
              />
              <Stat
                label="Emissions APR"
                value={statsPending ? "—" : apr(pool.emissionsApr)}
                accent={statsPending ? undefined : "var(--accent)"}
                sub={statsPending ? "arrives with the indexer" : undefined}
                tip="esFERA emissions, a separate stream, never blended into fee yield."
              />
              {statsPending ? (
                <Stat
                  label="Vault NAV"
                  value={
                    chain?.navQuote !== undefined
                      ? `${tokenAmt(chain.navQuote, 4)} ${chain.quoteSymbol}`
                      : "—"
                  }
                  sub="read on-chain"
                  tip="The vault's live net asset value for this pool, straight from quoteNav() on the contract."
                />
              ) : (
                <Stat label="TVL" value={usdCompact(pool.tvlUsd)} />
              )}
              <Stat
                label="Depth vs best"
                value={statsPending ? "—" : multiple(pool.depthVsBest)}
                sub={statsPending ? "arrives with the indexer" : "deeper than best venue"}
              />
            </>
          ) : (
            <>
              <Stat
                label="Price"
                value={m ? usdPrice(m.priceUsd) : "—"}
                tip="Live market price of the pair's base token, from real Robinhood Chain trades."
              />
              <Stat
                label="24h change"
                value={m ? signedPct(chg, 1) : "—"}
                accent={chg >= 0 ? "var(--pos)" : "var(--neg)"}
              />
              <Stat
                label="Market TVL"
                value={m ? usdCompact(m.tvlUsd) : "—"}
                sub="the venue pool, not the vault"
              />
              <Stat
                label="Vault APR"
                value="—"
                sub="opens at launch"
                tip="Fee yield and FERA emissions start when the vault contracts deploy. We don't show numbers that don't exist yet."
              />
            </>
          )}
        </div>
      </Card>

      {/* risk-profile picker (Active / Steady): RWA shows both, MEME shows Active only.
          Hidden pre-launch: there are no share classes to choose between yet. */}
      {vaultLive ? (
        <RiskClassSelector pool={pool} value={riskClass} onChange={setRiskClass} />
      ) : null}

      {/* two-column body */}
      <div className="grid gap-6 lg:grid-cols-[1.4fr_1fr]">
        <div className="space-y-6">
          {vaultLive ? (
            pool.regime === "MEME" ? (
              <>
                <BandLadder pool={pool} />
                <MemeExplainer />
              </>
            ) : (
              <OracleBand pool={pool} />
            )
          ) : (
            <>
              <PriceHistory poolId={pool.poolId} symbol={pool.token0.symbol} />
              <MemeExplainer />
            </>
          )}
          <OpenLiquidityNote />
          {/* no fee history to chart until the indexer has recorded some */}
          {vaultLive && pool.feeHistory.length ? <FeeHistory pool={pool} /> : null}
        </div>
        <div className="space-y-6">
          <YourPosition pool={pool} riskClass={riskClass} />
          {vaultLive ? (
            pool.strategyLog.length ? (
              <StrategyLog pool={pool} />
            ) : (
              <IndexerPendingCard />
            )
          ) : (
            <VaultAtLaunchCard />
          )}
        </div>
      </div>
    </div>
  );
}

/** Live vault, no indexer yet: history surfaces are pending, not zero. */
function IndexerPendingCard() {
  return (
    <Card>
      <CardHeader eyebrow="Vault" title="History is indexing" />
      <div className="px-5 pb-5">
        <p className="text-body-sm text-dim">
          This vault is live on-chain — the fee and NAV above are read straight from
          the contracts. Fee history, the strategy log and earnings breakdowns appear
          once the indexer backend is deployed and has synced the pool&apos;s events.
        </p>
      </div>
    </Card>
  );
}

/** Honest placeholder for every vault surface that can't exist before deployment. */
function VaultAtLaunchCard() {
  return (
    <Card>
      <CardHeader eyebrow="Vault" title="Opens at launch" />
      <div className="px-5 pb-5">
        <p className="text-body-sm text-dim">
          The dynamic fee, band ladder, fee history and strategy log appear here once
          the FERA vault contracts are deployed for this market. Until then we show
          only the real market — no simulated vault numbers.
        </p>
      </div>
    </Card>
  );
}
