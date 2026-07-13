"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { useCurrentEpoch, useClaimProof } from "@/lib/hooks/useApi";
import { Card, CardHeader } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { Skeleton } from "@/components/ui/Skeleton";
import { tokenAmt, shortHex } from "@/lib/format";
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
 * Merkle claim for the most recently FINALIZED epoch, from GET /epochs/:id/proof/:account (§8).
 * The current epoch (EpochPanel) is still accruing; the claimable root is the prior
 * epoch. Claiming is idempotent per (epochId, account, kind), INV-8.
 */
export function ClaimsCard() {
  const { address, isConnected } = useAccount();
  const { data: epoch } = useCurrentEpoch();
  const finalizedEpoch =
    epoch?.epochId !== undefined ? epoch.epochId - 1 : undefined;
  const { data: proof, isLoading } = useClaimProof(finalizedEpoch, address);
  const [claimed, setClaimed] = useState(false);

  return (
    <Card>
      <CardHeader
        eyebrow="Claim"
        title="Claimable esFERA"
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
            Connect a wallet to see your posted Merkle claim for the last epoch.
          </p>
        ) : isLoading ? (
          <Skeleton className="h-24 w-full rounded-lg" />
        ) : !proof ? (
          <p className="text-body-sm text-dim">
            Nothing to claim for epoch #{finalizedEpoch}. Emissions accrue for the
            current epoch (above) and become claimable once it finalizes.
          </p>
        ) : (
          <div className="space-y-4">
            <div className="flex items-end justify-between rounded-lg border border-line bg-well p-4">
              <div>
                <div className="mb-1 flex items-center gap-2">
                  <Badge color="var(--accent)" wash="var(--accent-wash)">
                    {KIND_LABEL[proof.kind]}
                  </Badge>
                  <span className="text-caption text-mute">
                    proof depth {proof.proof.length}
                  </span>
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
            <p className="text-caption text-mute font-mono tnum">
              leaf = keccak256(epochId={finalizedEpoch}, {shortHex(address ?? "0x")},
              kind={proof.kind}, amount) · claimable once (INV-8)
            </p>
            <p className="text-caption text-mute">
              Claimed esFERA lands in the vesting schedule below (6-mo linear →
              FERA 1:1). Real path: Distributor.claim(epochId, kind, amount, proof).
            </p>
          </div>
        )}
      </div>
    </Card>
  );
}
