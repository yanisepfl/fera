"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { Card, CardHeader } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { Modal } from "@/components/ui/Modal";
import { Skeleton } from "@/components/ui/Skeleton";
import { HaircutBreakdown } from "./HaircutBreakdown";
import { useVesting } from "@/lib/hooks/useApi";
import { weiToTokens, tokenAmt, countdownLabel } from "@/lib/format";
import type { VestingGrant } from "@/lib/types";

/**
 * esFERA vesting grants. Amounts arrive as 18-dec strings and are parsed with
 * weiToTokens for display only. esFERA vests linearly to FERA 1:1; exit early on
 * the still-locked remainder and you keep half, shown plainly before any confirm.
 */
export function VestingDashboard() {
  const { address, isConnected } = useAccount();
  const { data: grants, isLoading } = useVesting(address);
  const [exit, setExit] = useState<VestingGrant | null>(null);

  if (!isConnected) {
    return (
      <Card className="card-glow">
        <CardHeader
          eyebrow={<span className="text-accent">Vesting</span>}
          title="esFERA → FERA"
        />
        <div className="px-5 pb-5">
          <p className="text-body-sm text-dim">
            Connect a wallet to see your esFERA vesting grants.
          </p>
        </div>
      </Card>
    );
  }

  if (isLoading || !grants) return <Skeleton className="h-72 w-full rounded-lg" />;

  const totalClaimable = grants.reduce((s, g) => s + weiToTokens(g.claimable), 0);

  return (
    <Card className="card-glow">
      <CardHeader
        eyebrow={<span className="text-accent">Vesting</span>}
        title="esFERA → FERA"
        action={
          <div className="text-right">
            <div className="font-mono tnum text-body font-semibold text-pos">
              {tokenAmt(totalClaimable, 1)}
            </div>
            <div className="text-micro uppercase tracking-wide text-mute">claimable</div>
          </div>
        }
      />
      <div className="px-5 pb-5 space-y-3">
        {grants.map((g) => {
          const amount = weiToTokens(g.amount);
          const vested = weiToTokens(g.vested);
          const claimable = weiToTokens(g.claimable);
          const unvested = Math.max(0, amount - vested);
          const frac = amount > 0 ? vested / amount : 0;
          return (
            <div key={g.grantId} className="rounded-lg border border-line bg-well p-4">
              <div className="flex items-baseline justify-between">
                <span className="font-mono tnum text-body font-semibold text-text">
                  {tokenAmt(amount, 1)} esFERA
                </span>
                <span className="text-caption text-mute">
                  {countdownLabel(g.endTs)} left
                </span>
              </div>

              {/* progress */}
              <div className="mt-2 h-2 overflow-hidden rounded-full bg-surface">
                <div
                  className="h-full rounded-full bg-accent"
                  style={{ width: `${(frac * 100).toFixed(1)}%` }}
                />
              </div>
              <div className="mt-1.5 flex justify-between text-caption text-mute font-mono tnum">
                <span>{(frac * 100).toFixed(0)}% vested</span>
                <span>{tokenAmt(unvested, 1)} still locked</span>
              </div>

              <div className="mt-3 flex gap-2">
                <Button size="sm" disabled={claimable <= 0}>
                  Claim {tokenAmt(claimable, 1)} FERA
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-danger hover:bg-danger-wash"
                  disabled={unvested <= 0}
                  onClick={() => setExit(g)}
                >
                  Instant exit…
                </Button>
              </div>
            </div>
          );
        })}
      </div>

      {/* instant-exit confirmation, forfeiture shown BEFORE confirm */}
      <Modal open={!!exit} onClose={() => setExit(null)} title="Confirm instant exit">
        {exit ? <ExitConfirm grant={exit} onClose={() => setExit(null)} /> : null}
      </Modal>
    </Card>
  );
}

function ExitConfirm({ grant, onClose }: { grant: VestingGrant; onClose: () => void }) {
  const amount = weiToTokens(grant.amount);
  const vested = weiToTokens(grant.vested);
  const unvested = Math.max(0, amount - vested);
  const [confirmed, setConfirmed] = useState(false);
  return (
    <div className="p-5 space-y-4">
      <p className="text-body-sm text-dim">
        Exiting the locked{" "}
        <span className="font-mono text-text">{tokenAmt(unvested, 2)}</span> esFERA of this
        grant right now, instead of waiting {countdownLabel(grant.endTs)}.
      </p>

      <HaircutBreakdown amount={unvested} />

      <label className="flex items-start gap-2 text-body-sm text-dim">
        <input
          type="checkbox"
          checked={confirmed}
          onChange={(e) => setConfirmed(e.target.checked)}
          className="mt-0.5 accent-[var(--danger)]"
        />
        <span>I understand I am permanently forfeiting half of this esFERA.</span>
      </label>

      <div className="flex gap-2">
        <Button variant="secondary" className="flex-1" onClick={onClose}>
          Keep vesting
        </Button>
        <Button variant="danger" className="flex-1" disabled={!confirmed}>
          Exit &amp; forfeit
        </Button>
      </div>
    </div>
  );
}
