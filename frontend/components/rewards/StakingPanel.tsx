"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { useStaking } from "@/lib/hooks/useApi";
import { Card, CardHeader } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { Skeleton } from "@/components/ui/Skeleton";
import { InfoTip } from "@/components/ui/InfoTip";
import { apr, tokenAmt, num, multiple } from "@/lib/format";

const MAX_BOOST = 2; // §7 "Max boost ~2x" — on the staker's OWN emissions only.

/**
 * sFERA staking (AnchorStaking). Stake FERA → earn TWO distinct things:
 *   1. REVENUE-SHARE APR — real yield, the 50% staker cut of protocol revenue
 *      (RevenueDistributor, INV-10). Paid in actual fee tokens. Shown in green.
 *   2. A BOOST (≤2x) on your OWN trader/LP emissions, accrued via multiplier points.
 * The two are rendered separately on purpose: real yield is NOT a token-emission APR
 * and must never be blended with esFERA emissions (§8 StakingSummary note).
 */
export function StakingPanel() {
  const { address, isConnected } = useAccount();
  const { data: staking, isLoading } = useStaking(address);
  const [amount, setAmount] = useState("");

  return (
    <Card>
      <CardHeader
        eyebrow="Stake"
        title="sFERA — stake for real yield + boost"
        action={
          <InfoTip text="Staking FERA mints sFERA. It earns the 50% staker cut of real protocol revenue (revenue-share APR) and boosts your own emissions up to ~2x. Boost never mints new tokens — it re-weights a fixed capped pool (INV-7 / PT-5)." />
        }
      />

      <div className="px-5 pb-5 space-y-5">
        {!isConnected ? (
          <div className="space-y-3">
            <p className="text-body-sm text-dim">
              Connect a wallet to stake FERA. Staking earns real revenue share (paid
              in fee tokens) plus a boost on your own emissions.
            </p>
          </div>
        ) : isLoading || !staking ? (
          <Skeleton className="h-56 w-full rounded-lg" />
        ) : (
          <>
            {/* two DISTINCT yield sources */}
            <div className="grid grid-cols-2 gap-3">
              <div className="rounded-lg border border-line bg-well p-4">
                <div className="mb-1 flex items-center gap-1">
                  <span className="overline text-pos">Revenue-share APR</span>
                  <InfoTip text="REAL yield. Your share of the 50% of protocol revenue routed to stakers (INV-10), paid in the fee tokens themselves (USDG, WETH…). Not a token emission." />
                </div>
                <div className="font-mono tnum text-display-l font-semibold text-pos">
                  {apr(staking.revenueShareApr)}
                </div>
                <div className="text-caption text-mute">real yield · paid in fees</div>
              </div>
              <div className="rounded-lg border border-line bg-well p-4">
                <div className="mb-1 flex items-center gap-1">
                  <span className="overline text-accent">Emissions boost</span>
                  <InfoTip text="Multiplier on the esFERA emissions you earn from your OWN trading + LPing. Token emission, kept separate from the real revenue-share yield on the left." />
                </div>
                <div className="font-mono tnum text-display-l font-semibold text-accent">
                  {multiple(staking.boost)}
                </div>
                <div className="text-caption text-mute">on your own esFERA</div>
              </div>
            </div>

            {/* boost meter */}
            <div>
              <div className="mb-1.5 flex items-center justify-between text-caption text-mute">
                <span>Boost</span>
                <span className="font-mono tnum">
                  {multiple(staking.boost)} / {multiple(MAX_BOOST)} max
                </span>
              </div>
              <div className="relative h-2.5 overflow-hidden rounded-full bg-surface">
                <div
                  className="h-full rounded-full bg-accent"
                  style={{
                    width: `${Math.min(
                      100,
                      ((staking.boost - 1) / (MAX_BOOST - 1)) * 100
                    ).toFixed(1)}%`,
                  }}
                />
              </div>
              <div className="mt-1 flex justify-between text-micro text-mute font-mono tnum">
                <span>1.0x</span>
                <span>2.0x</span>
              </div>
            </div>

            {/* position stats */}
            <div className="grid grid-cols-2 gap-4">
              <div>
                <div className="overline mb-1">sFERA staked</div>
                <div className="font-mono tnum text-heading font-semibold text-text">
                  {num(staking.sFera)}
                </div>
              </div>
              <div>
                <div className="mb-1 flex items-center gap-1">
                  <span className="overline">Multiplier points</span>
                  <InfoTip text="Accrue while staked and decay linearly on unstake — they carry the boost. Longer stakes hold a higher boost." />
                </div>
                <div className="font-mono tnum text-heading font-semibold text-text">
                  {num(staking.multiplierPoints)}
                </div>
              </div>
            </div>

            {/* stake input (mocked tx) */}
            <label className="block">
              <span className="overline">Stake FERA</span>
              <div className="mt-1 flex items-center gap-2 rounded-lg border border-line bg-surface px-3 py-2.5 focus-within:border-accent-line">
                <input
                  inputMode="decimal"
                  placeholder="0.00"
                  value={amount}
                  onChange={(e) =>
                    setAmount(e.target.value.replace(/[^0-9.]/g, ""))
                  }
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
            <p className="text-caption text-mute">
              Real path: AnchorStaking.stake(amount, lockWeeks) via wagmi
              useWriteContract. Revenue share is pull-based per token.
            </p>
          </>
        )}
      </div>
    </Card>
  );
}
