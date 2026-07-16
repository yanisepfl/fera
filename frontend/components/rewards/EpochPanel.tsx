"use client";

import { useEffect, useState } from "react";
import { useCurrentEpoch } from "@/lib/hooks/useApi";
import { Card } from "@/components/ui/Card";
import { Skeleton } from "@/components/ui/Skeleton";
import { LiveDot } from "@/components/ui/LiveDot";
import { InfoTip } from "@/components/ui/InfoTip";
import { CountUp } from "@/components/viz/CountUp";
import { countdown, usd, weiToTokens } from "@/lib/format";

/** Re-render every second so the epoch clock ticks. Only mounts client-side. */
function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}

/**
 * Current (unfinalized) weekly epoch, from GET /epochs/current.
 * Shows the countdown to close, the account's fees paid (drives the 5% trader
 * bucket) vs fees earned (drives the 85% LP bucket), and the projected esFERA at
 * the current pace. Nothing here is claimable yet. That happens once the epoch
 * finalizes on-chain (see ClaimsCard).
 */
export function EpochPanel() {
  const { data: epoch, isLoading } = useCurrentEpoch();
  const now = useNow();

  if (isLoading || !epoch)
    return <Skeleton className="h-44 w-full rounded-lg" />;

  // PRE-LAUNCH LIVE MODE: no epoch exists on-chain yet — say so instead of
  // counting down to nothing or showing $0.00 as if it were a measured balance.
  if (epoch.vaultLive === false) {
    return (
      <Card className="card-glow overflow-hidden">
        <div className="flex flex-col gap-3 p-6 md:p-7">
          <div className="overline">Epochs</div>
          <h3 className="text-heading font-semibold text-text">
            Weekly epochs start at launch
          </h3>
          <p className="max-w-xl text-body-sm text-dim">
            Rewards run in weekly epochs: fees you pay and earn are tallied, then
            esFERA becomes claimable when each epoch closes. The contracts aren&apos;t
            deployed yet, so nothing is accruing — there are no numbers to show here,
            and we won&apos;t invent any.
          </p>
        </div>
      </Card>
    );
  }

  const c = countdown(epoch.endsAt, now);

  return (
    <Card className="card-glow overflow-hidden">
      <div className="grid gap-6 p-6 md:grid-cols-[1fr_1.3fr] md:p-7">
        {/* countdown */}
        <div className="flex flex-col justify-between gap-5 rounded-lg border border-line bg-well/60 p-5">
          <div className="flex items-center justify-between">
            <div>
              <div className="overline mb-1">Epoch #{epoch.epochId}</div>
              <div className="text-body-sm text-dim">closes in</div>
            </div>
            <LiveDot label="LIVE" />
          </div>
          <div className="flex items-end gap-2" aria-label="Time remaining in epoch">
            <TimeBlock v={c.d} unit="d" />
            <TimeBlock v={c.h} unit="h" />
            <TimeBlock v={c.m} unit="m" />
            <TimeBlock v={c.s} unit="s" dim />
          </div>
          <p className="text-caption text-mute">
            A new epoch every week. When it closes, your rewards are finalized on-chain
            and become claimable.
          </p>
        </div>

        {/* your epoch economics */}
        <div className="grid grid-cols-2 gap-5 self-center sm:grid-cols-3">
          <div>
            <div className="mb-1 flex items-center gap-1">
              <span className="overline">Fees paid</span>
              <InfoTip text="Fees you paid as a trader this epoch. This sets your share of trader emissions." />
            </div>
            <div className="font-mono tnum text-title font-semibold text-text">
              {usd(epoch.feesPaid)}
            </div>
            <div className="text-caption text-mute">as a trader → rebate</div>
          </div>
          <div>
            <div className="mb-1 flex items-center gap-1">
              <span className="overline">Fees earned</span>
              <InfoTip text="Fees you earned as an LP this epoch, after the 10% performance fee. This sets your share of LP emissions." />
            </div>
            <div className="font-mono tnum text-title font-semibold text-pos">
              {usd(epoch.feesEarned)}
            </div>
            <div className="text-caption text-mute">as an LP → share</div>
          </div>
          <div className="col-span-2 sm:col-span-1">
            <div className="mb-1 flex items-center gap-1">
              <span className="overline text-accent">Projected esFERA</span>
              <InfoTip text="Estimated esFERA for you at the current pace. It is fixed only when the epoch closes." />
            </div>
            <div className="text-title font-semibold text-accent">
              <CountUp value={weiToTokens(epoch.projectedEsFera)} decimals={1} />
            </div>
            <div className="text-caption text-mute">projected, at current pace</div>
          </div>
        </div>
      </div>
    </Card>
  );
}

function TimeBlock({ v, unit, dim }: { v: number; unit: string; dim?: boolean }) {
  return (
    <div className="flex items-end gap-1">
      <span
        className={
          "font-mono tnum text-display-l font-semibold leading-none " +
          (dim ? "text-dim" : "text-text")
        }
      >
        {String(v).padStart(2, "0")}
      </span>
      <span className="mb-1 text-caption text-mute">{unit}</span>
    </div>
  );
}
