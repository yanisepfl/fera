"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { useCurrentEpoch, useClaimProof } from "@/lib/hooks/useApi";
import { Card, CardHeader } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { Skeleton } from "@/components/ui/Skeleton";
import { tokenAmt } from "@/lib/format";
import type { ClaimKind } from "@/lib/types";

const KIND_LABEL: Record<ClaimKind, string> = {
  0: "Trader rebate",
  1: "LP reward",
};

/** esFERA is 18-dec; the proof carries a string amount to preserve precision. */
function fromWei(amount: string): number {
  return Number(amount) / 1e18;
}

/**
 * Claim your esFERA emissions from the most recently finalized epoch. These are
 * earned from your own LPing and trading, then vest to FERA. This is separate
 * from the staking revenue share (real fee tokens), which is claimed in the
 * Staking panel.
 */
export function ClaimsCard() {
  const { address, isConnected } = useAccount();
  const { data: epoch } = useCurrentEpoch();
  const finalizedEpoch =
    epoch?.epochId !== undefined ? epoch.epochId - 1 : undefined;
  const { data: proof, isLoading } = useClaimProof(finalizedEpoch, address);
  const [claimed, setClaimed] = useState(false);

  return (
    <Card className="card-glow">
      <CardHeader
        eyebrow={<span className="text-accent">Claim</span>}
        title="Your esFERA emissions"
        action={
          finalizedEpoch !== undefined ? (
            <span className="text-caption text-mute">
              epoch #{finalizedEpoch} · finalized
            </span>
          ) : null
        }
      />
      <div className="px-5 pb-5">
        {!isConnected ? (
          <p className="text-body-sm text-dim">
            Connect a wallet to see the esFERA you earned last epoch.
          </p>
        ) : isLoading ? (
          <Skeleton className="h-24 w-full rounded-lg" />
        ) : !proof ? (
          <p className="text-body-sm text-dim">
            Nothing to claim for epoch #{finalizedEpoch}. Emissions accrue for the
            current epoch (above) and become claimable once it closes.
          </p>
        ) : (
          <div className="space-y-4">
            <div className="flex items-end justify-between rounded-lg border border-line bg-well p-4">
              <div>
                <div className="mb-1 flex items-center gap-2">
                  <Badge color="var(--accent)" wash="var(--accent-wash)">
                    {KIND_LABEL[proof.kind]}
                  </Badge>
                </div>
                <div className="font-mono tnum text-display-l font-semibold text-accent">
                  {tokenAmt(fromWei(proof.amount), 2)}
                </div>
                <div className="text-caption text-mute">esFERA</div>
              </div>
              <Button
                size="md"
                disabled={claimed}
                onClick={() => setClaimed(true)}
              >
                {claimed ? "Claimed ✓" : "Claim"}
              </Button>
            </div>
            <p className="text-caption text-mute">
              Earned from your LPing and trading. Claimed esFERA vests to FERA over
              about 6 months, 1:1.
            </p>
          </div>
        )}
      </div>
    </Card>
  );
}
