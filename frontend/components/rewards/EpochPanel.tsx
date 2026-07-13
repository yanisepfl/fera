"use client";

import { useEffect, useState } from "react";
import { useCurrentEpoch } from "@/lib/hooks/useApi";
import { Card } from "@/components/ui/Card";
import { Skeleton } from "@/components/ui/Skeleton";
import { LiveDot } from "@/components/ui/LiveDot";
import { InfoTip } from "@/components/ui/InfoTip";
import { countdown, usd, esFera } from "@/lib/format";

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
 * Current (unfinalized) weekly epoch, from GET /epochs/current (§8).
 * Shows the countdown to close, the account's fees PAID (drives the 5% trader
 * bucket) vs fees EARNED (drives the 85% LP bucket), and the projected esFERA at
 * the current pro-rata. Nothing here is claimable yet. That happens once the
 * epoch finalizes and a Merkle root is posted (see ClaimsCard).
 */
export function EpochPanel() {
  const { data: epoch, isLoading } = useCurrentEpoch();
  const now = useNow();

  if (isLoading || !epoch)
    return <Skeleton className="h-44 w-full rounded-lg" />;

  const c = countdown(epoch.endsAt, now);

  return (
    <Card className="overflow-hidden">
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
            Weekly epochs. At close, Backend snapshots events, computes the Merkle
            root (§9), and a keeper posts it on-chain. Then rewards become claimable.
          </p>
        </div>

        {/* your epoch economics */}
        <div className="grid grid-cols-2 gap-5 self-center sm:grid-cols-3">
          <div>
            <div className="mb-1 flex items-center gap-1">
              <span className="overline">Fees paid</span>
              <InfoTip text="Fees you paid as a TRADER this epoch. Drives your pro-rata slice of the 5% trader-rebate emission bucket (§7 · 85/5/10)." />
            </div>
            <div className="font-mono tnum text-title font-semibold text-text">
              {usd(epoch.feesPaid)}
            </div>
            <div className="text-caption text-mute">as a trader → rebate</div>
          </div>
          <div>
            <div className="mb-1 flex items-center gap-1">
              <span className="overline">Fees earned</span>
              <InfoTip text="Fees you earned as an LP this epoch (net of the 10% perf fee). Drives your slice of the 85% LP emission bucket (§7 · 85/5/10)." />
            </div>
            <div className="font-mono tnum text-title font-semibold text-pos">
              {usd(epoch.feesEarned)}
            </div>
            <div className="text-caption text-mute">as an LP → share</div>
          </div>
          <div className="col-span-2 sm:col-span-1">
            <div className="mb-1 flex items-center gap-1">
              <span className="overline">Projected esFERA</span>
              <InfoTip text="Estimated esFERA for this account at the current pro-rata. Final amount is fixed only when the epoch closes and the root is posted." />
            </div>
            <div className="font-mono tnum text-title font-semibold text-accent">
              {esFera(epoch.projectedEsFera)}
            </div>
            <div className="text-caption text-mute">at current pro-rata</div>
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
