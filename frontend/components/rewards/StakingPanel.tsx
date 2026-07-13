"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { useStaking } from "@/lib/hooks/useApi";
import { Card, CardHeader } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { Skeleton } from "@/components/ui/Skeleton";
import { InfoTip } from "@/components/ui/InfoTip";
import { apr, tokenAmt, num, multiple } from "@/lib/format";

const MAX_BOOST = 2; // Max boost ~2x, on the staker's OWN emissions only.

/**
 * Stake FERA, then earn two distinct things:
 *   1. A REVENUE SHARE: real fee tokens, the staker cut of protocol revenue.
 *      One Claim button pays it out. Shown in green (real yield, not emissions).
 *   2. A BOOST (up to ~2x) on your own emissions. Shown in Cove.
 * Kept separate on purpose: real yield is never blended with token emissions.
 */
export function StakingPanel() {
  const { address, isConnected } = useAccount();
  const { data: staking, isLoading } = useStaking(address);
  const [amount, setAmount] = useState("");
  const [claimed, setClaimed] = useState(false);

  return (
    <Card className="card-glow">
      <CardHeader
        eyebrow={<span className="text-pos">Stake</span>}
        title="Stake FERA. Earn real revenue."
        action={
          <InfoTip text="Staking FERA earns you a share of real protocol revenue, paid in actual fee tokens. It also boosts your own emissions up to about 2x. The boost re-weights a fixed, capped pool. It never mints new tokens." />
        }
      />

      <div className="px-5 pb-5 space-y-5">
        {!isConnected ? (
          <p className="text-body-sm text-dim">
            Connect a wallet to stake FERA. Staking earns a share of real revenue,
            paid in fee tokens, plus a boost on your own emissions.
          </p>
        ) : isLoading || !staking ? (
          <Skeleton className="h-56 w-full rounded-lg" />
        ) : (
          <>
            {/* two distinct earnings: real yield (green) + boost (Cove) */}
            <div className="grid grid-cols-2 gap-3">
              <div className="rounded-lg border border-line bg-well p-4">
                <div className="mb-1 overline text-pos">Revenue share</div>
                <div className="font-mono tnum text-display-l font-semibold text-pos">
                  {apr(staking.revenueShareApr)}
                </div>
                <div className="text-caption text-mute">real yield · paid in fees</div>
              </div>
              <div className="rounded-lg border border-line bg-well p-4">
                <div className="mb-1 overline text-accent2">Emissions boost</div>
                <div className="font-mono tnum text-display-l font-semibold text-accent2">
                  {multiple(staking.boost)}
                </div>
                <div className="text-caption text-mute">on your own esFERA</div>
              </div>
            </div>

            {/* boost meter, Cove */}
            <div>
              <div className="mb-1.5 flex items-center justify-between text-caption text-mute">
                <span>Boost</span>
                <span className="font-mono tnum">
                  {multiple(staking.boost)} / {multiple(MAX_BOOST)} max
                </span>
              </div>
              <div className="relative h-2.5 overflow-hidden rounded-full bg-surface">
                <div
                  className="h-full rounded-full bg-accent2"
                  style={{
                    width: `${Math.min(
                      100,
                      ((staking.boost - 1) / (MAX_BOOST - 1)) * 100
                    ).toFixed(1)}%`,
                  }}
                />
              </div>
              <div className="mt-1 flex justify-between text-micro text-mute">
                <span>Stake longer, boost higher</span>
                <span className="font-mono tnum">{num(staking.sFera)} sFERA staked</span>
              </div>
            </div>

            {/* one clear Claim action for the real revenue share */}
            <div className="flex items-center justify-between rounded-lg border border-line bg-well p-4">
              <div>
                <div className="text-body-sm font-semibold text-text">
                  Your revenue share
                </div>
                <div className="text-caption text-mute">real fee tokens, ready to claim</div>
              </div>
              <Button
                size="md"
                disabled={claimed || staking.sFera <= 0}
                onClick={() => setClaimed(true)}
              >
                {claimed ? "Claimed ✓" : "Claim"}
              </Button>
            </div>

            {/* add to stake */}
            <label className="block">
              <span className="overline">Stake FERA</span>
              <div className="mt-1 flex items-center gap-2 rounded-lg border border-line bg-surface px-3 py-2.5 focus-within:border-accent-line">
                <input
                  inputMode="decimal"
                  placeholder="0.00"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))}
                  className="w-full bg-transparent font-mono tnum text-title outline-none placeholder:text-mute"
                />
                <span className="text-body-sm text-dim">FERA</span>
              </div>
            </label>
            <Button
              className="w-full"
              size="lg"
              disabled={!amount || Number(amount) <= 0}
            >
              Stake {amount ? `${tokenAmt(Number(amount), 2)} FERA` : ""}
            </Button>
          </>
        )}
      </div>
    </Card>
  );
}
