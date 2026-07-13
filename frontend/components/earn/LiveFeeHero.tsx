"use client";

import Link from "next/link";
import type { PoolSummary, MarketHoursState } from "@/lib/types";
import { LiveFee } from "./LiveFee";
import { DepositDialog } from "./DepositDialog";
import { LiveDot } from "@/components/ui/LiveDot";
import { RegimeBadge } from "@/components/ui/Badge";
import { TokenPair } from "@/components/ui/TokenPair";
import { Button } from "@/components/ui/Button";
import { useLiveFee } from "@/lib/hooks/useLiveFee";
import { feeReason, TONE_COLOR } from "@/lib/feeReason";
import { apr, usdCompact, multiple } from "@/lib/format";

/**
 * Earn-home centerpiece: one flagship pool with its LIVE dynamic fee as the hero
 * number, the WHY beneath it, the APY split (fee-yield vs emissions), TVL, and the
 * depth claim ("deepest NVDA/USDG pool"). 2-click deposit inline.
 */
export function LiveFeeHero({
  pool,
  marketState,
  depthLabel,
}: {
  pool: PoolSummary;
  marketState?: MarketHoursState | null;
  depthLabel: string;
}) {
  // Read the same live value the hero prints so the "why" tracks the number.
  const { pips } = useLiveFee(pool.currentFeePips, pool.regime);
  const reason = feeReason(pool.regime, pips, marketState);

  return (
    <div className="relative overflow-hidden rounded-lg border border-line bg-card shadow-glow-accent">
      <div
        className="pointer-events-none absolute -right-24 -top-24 h-64 w-64 rounded-full opacity-[0.08] blur-3xl"
        style={{ background: "var(--accent)" }}
      />
      <div className="grid gap-6 p-6 md:grid-cols-[1.2fr_1fr] md:p-8">
        {/* left: live fee hero */}
        <div>
          <div className="mb-4 flex items-center gap-3">
            <TokenPair token0={pool.token0} token1={pool.token1} />
            <RegimeBadge regime={pool.regime} />
          </div>

          <div className="mb-1 flex items-center gap-2">
            <LiveDot label="LIVE FEE" />
            <span className="text-caption text-mute">
              dynamic · updates every ~1s
            </span>
          </div>

          <LiveFee seedPips={pool.currentFeePips} regime={pool.regime} size="hero" />

          <div className="mt-4 flex items-start gap-2">
            <span
              className="mt-1.5 h-2 w-2 shrink-0 rounded-full"
              style={{ background: TONE_COLOR[reason.tone] }}
            />
            <div>
              <div
                className="text-body font-medium"
                style={{ color: TONE_COLOR[reason.tone] }}
              >
                {reason.headline}
              </div>
              <p className="mt-0.5 max-w-md text-body-sm text-dim">
                {reason.detail}
              </p>
            </div>
          </div>
        </div>

        {/* right: economics + deposit */}
        <div className="flex flex-col justify-between gap-5 rounded-lg border border-line bg-well/60 p-5">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <div className="overline mb-1">Fee-yield APR</div>
              <div className="font-mono tnum text-title font-semibold text-pos">
                {apr(pool.feeApr)}
              </div>
              <div className="text-caption text-mute">net of 10% perf fee</div>
            </div>
            <div>
              <div className="overline mb-1">Emissions APR</div>
              <div className="font-mono tnum text-title font-semibold text-accent">
                {apr(pool.emissionsApr)}
              </div>
              <div className="text-caption text-mute">esFERA · vests 6mo</div>
            </div>
            <div>
              <div className="overline mb-1">TVL</div>
              <div className="font-mono tnum text-heading font-semibold text-text">
                {usdCompact(pool.tvlUsd)}
              </div>
            </div>
            <div>
              <div className="overline mb-1">Depth vs best</div>
              <div className="font-mono tnum text-heading font-semibold text-text">
                {multiple(pool.depthVsBest)}
              </div>
              <div className="text-caption text-pos">{depthLabel}</div>
            </div>
          </div>

          <div className="flex gap-2">
            <DepositDialog
              pool={pool}
              trigger={(open) => (
                <Button size="lg" className="flex-1" onClick={open}>
                  Deposit
                </Button>
              )}
            />
            <Link href={`/app/pool/${pool.poolId}`}>
              <Button size="lg" variant="secondary">
                Pool
              </Button>
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}
