"use client";

import { useAccount } from "wagmi";
import type { PoolSummary, RiskClass } from "@/lib/types";
import { usePositions } from "@/lib/hooks/useApi";
import { Card, CardHeader } from "@/components/ui/Card";
import { Stat } from "@/components/ui/Stat";
import { DepositDialog } from "@/components/earn/DepositDialog";
import { WithdrawDialog } from "@/components/earn/WithdrawDialog";
import { Button } from "@/components/ui/Button";
import { usd, esFera } from "@/lib/format";
import { RISK_CLASS_META } from "@/lib/riskClass";
import { RISK_CLASS_BY_TRANCHE } from "@/lib/types";

/** The connected wallet's shares + earnings in this pool. */
export function YourPosition({
  pool,
  riskClass,
}: {
  pool: PoolSummary;
  riskClass?: RiskClass;
}) {
  const { address, isConnected } = useAccount();
  const { data: positions } = usePositions(address);
  const pos = positions?.find((p) => p.poolId === pool.poolId);
  const posClass =
    pos && pos.tranche !== undefined ? RISK_CLASS_BY_TRANCHE[pos.tranche] : undefined;

  return (
    <Card>
      <CardHeader eyebrow="Your position" title="Shares & earnings" />
      <div className="px-5 pb-5">
        {!isConnected ? (
          <div className="flex flex-col items-start gap-3">
            <p className="text-body-sm text-dim">
              Connect a wallet to see your vault shares, fees earned, and pending
              rewards for this pool.
            </p>
            <DepositDialog pool={pool} defaultRiskClass={riskClass} />
          </div>
        ) : !pos ? (
          <div className="flex flex-col items-start gap-3">
            <p className="text-body-sm text-dim">
              You&apos;re not providing to this pool yet.
            </p>
            <DepositDialog pool={pool} defaultRiskClass={riskClass} />
          </div>
        ) : (
          <>
            {posClass ? (
              <div className="mb-3 inline-flex items-center gap-1.5 rounded-full border border-line bg-well px-2 py-0.5 text-caption">
                <span
                  className="h-1.5 w-1.5 rounded-full"
                  style={{ background: RISK_CLASS_META[posClass].color }}
                />
                <span className="text-dim">{RISK_CLASS_META[posClass].label} profile</span>
              </div>
            ) : null}
            <div className="grid grid-cols-2 gap-5 sm:grid-cols-4">
              <Stat
                label="Vault shares"
                value={pos.shares.toLocaleString("en-US", { maximumFractionDigits: 2 })}
                tip="Fungible ERC-20 vault shares, usable across the chain's DeFi."
              />
              <Stat label="Value" value={usd(pos.valueUsd)} />
              <Stat
                label="Fees earned"
                value={usd(pos.feesEarned)}
                accent="var(--pos)"
                sub="net of 10% perf fee"
              />
              <Stat
                label="esFERA pending"
                value={esFera(pos.emissionsPending)}
                accent="var(--accent)"
                sub="claim in Rewards"
              />
            </div>
            <div className="mt-4 flex gap-2">
              <DepositDialog
                pool={pool}
                defaultRiskClass={posClass ?? riskClass}
                trigger={(open) => (
                  <Button size="sm" onClick={open}>
                    Add
                  </Button>
                )}
              />
              <WithdrawDialog
                pool={pool}
                position={pos}
                trigger={(open) => (
                  <Button size="sm" variant="secondary" onClick={open}>
                    Withdraw
                  </Button>
                )}
              />
            </div>
          </>
        )}
      </div>
    </Card>
  );
}
