"use client";

import Link from "next/link";
import { useState } from "react";
import type { PoolId, RiskClass } from "@/lib/types";
import { usePool } from "@/lib/hooks/useApi";
import { RegimeBadge } from "@/components/ui/Badge";
import { TokenPair } from "@/components/ui/TokenPair";
import { LiveFee } from "@/components/earn/LiveFee";
import { LiveDot } from "@/components/ui/LiveDot";
import { Stat } from "@/components/ui/Stat";
import { Skeleton } from "@/components/ui/Skeleton";
import { Card } from "@/components/ui/Card";
import { ErrorState } from "@/components/ui/ErrorState";
import { MemeExplainer } from "./MemeExplainer";
import { BandLadder } from "./BandLadder";
import { OracleBand } from "./OracleBand";
import { FeeHistory } from "./FeeHistory";
import { StrategyLog } from "./StrategyLog";
import { YourPosition } from "./YourPosition";
import { RiskClassSelector } from "./RiskClassSelector";
import { OpenLiquidityNote } from "./OpenLiquidityNote";
import { apr, usdCompact, multiple } from "@/lib/format";

export function PoolDetailView({ poolId }: { poolId: PoolId }) {
  const { data: pool, isLoading, error, refetch } = usePool(poolId);
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

  return (
    <div className="space-y-6">
      {/* header */}
      <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
        <div className="flex items-center gap-3">
          <Link href="/app" className="text-mute hover:text-dim text-body-sm">
            ← Earn
          </Link>
          <TokenPair token0={pool.token0} token1={pool.token1} className="text-title" />
          <RegimeBadge regime={pool.regime} />
        </div>
        <div className="flex items-center gap-2">
          <LiveDot label="LIVE FEE" />
          <LiveFee seedPips={pool.currentFeePips} regime={pool.regime} />
        </div>
      </div>

      {/* headline stats */}
      <Card>
        <div className="grid grid-cols-2 gap-5 p-5 sm:grid-cols-4">
          <Stat
            label="Fee-yield APR"
            value={apr(pool.feeApr)}
            accent="var(--pos)"
            tip="Trailing LP fee yield, net of the 10% performance fee. Half of that fee flows to stakers."
          />
          <Stat
            label="Emissions APR"
            value={apr(pool.emissionsApr)}
            accent="var(--accent)"
            tip="esFERA emissions, a separate stream, never blended into fee yield."
          />
          <Stat label="TVL" value={usdCompact(pool.tvlUsd)} />
          <Stat
            label="Depth vs best"
            value={multiple(pool.depthVsBest)}
            sub="deeper than best venue"
          />
        </div>
      </Card>

      {/* risk-profile picker (Active / Steady): RWA shows both, MEME shows Active only */}
      <RiskClassSelector pool={pool} value={riskClass} onChange={setRiskClass} />

      {/* two-column body */}
      <div className="grid gap-6 lg:grid-cols-[1.4fr_1fr]">
        <div className="space-y-6">
          {pool.regime === "MEME" ? (
            <>
              <BandLadder pool={pool} />
              <MemeExplainer />
            </>
          ) : (
            <OracleBand pool={pool} />
          )}
          <OpenLiquidityNote />
          <FeeHistory pool={pool} />
        </div>
        <div className="space-y-6">
          <YourPosition pool={pool} riskClass={riskClass} />
          <StrategyLog pool={pool} />
        </div>
      </div>
    </div>
  );
}
