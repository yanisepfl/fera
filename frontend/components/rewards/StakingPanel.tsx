"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { useStaking } from "@/lib/hooks/useApi";
import { Card, CardHeader } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { Skeleton } from "@/components/ui/Skeleton";
import { InfoTip } from "@/components/ui/InfoTip";
import { apr, tokenAmt, num } from "@/lib/format";

/**
 * The SIMPLE staking model: stake FERA → earn a pro-rata share of real protocol
 * revenue (actual fee tokens), accruing continuously. No boosts, no lock tiers,
 * no decay — the one rule is a 7-day unstake cooldown after your last stake
 * (an anti-gaming guard; topping up restarts it).
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
          <InfoTip text="Staking FERA earns you a share of real protocol revenue, paid in actual fee tokens and accruing every second. One simple rule: after you stake (or top up), there's a 7-day wait before you can unstake — so nobody can jump in and out around big revenue days." />
        }
      />

      <div className="px-5 pb-5 space-y-5">
        {!isConnected ? (
          <p className="text-body-sm text-dim">
            Connect a wallet to stake FERA. Staking earns a share of real
            revenue, paid in fee tokens, accruing every second you&apos;re staked.
          </p>
        ) : isLoading || !staking ? (
          <Skeleton className="h-56 w-full rounded-lg" />
        ) : (
          <>
            {/* one earning: the real revenue share */}
            <div className="rounded-lg border border-line bg-well p-4">
              <div className="mb-1 flex items-center justify-between">
                <span className="overline text-pos">Revenue share</span>
                <span className="font-mono tnum text-caption text-mute">
                  {num(staking.sFera)} FERA staked
                </span>
              </div>
              <div className="font-mono tnum text-display-l font-semibold text-pos">
                {apr(staking.revenueShareApr)}
              </div>
              <div className="text-caption text-mute">
                real yield · paid in fee tokens · accrues continuously
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
            <p className="text-micro text-mute">
              Unstaking opens 7 days after your last stake — topping up restarts
              the clock on your whole balance. Claiming rewards is never delayed.
            </p>
          </>
        )}
      </div>
    </Card>
  );
}
