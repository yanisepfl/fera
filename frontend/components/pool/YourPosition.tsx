"use client";

import { useAccount } from "wagmi";
import { formatUnits } from "viem";
import type { PoolSummary, Position, RiskClass } from "@/lib/types";
import { usePositions } from "@/lib/hooks/useApi";
import { useVaultWithdraw } from "@/lib/hooks/useVaultTx";
import { livePoolById } from "@/config/pools";
import { Card, CardHeader } from "@/components/ui/Card";
import { Stat } from "@/components/ui/Stat";
import { Skeleton } from "@/components/ui/Skeleton";
import { DepositDialog } from "@/components/earn/DepositDialog";
import { WithdrawDialog } from "@/components/earn/WithdrawDialog";
import { Button } from "@/components/ui/Button";
import { usd, esFera, tokenAmt } from "@/lib/format";
import { RISK_CLASS_META } from "@/lib/riskClass";
import { RISK_CLASS_BY_TRANCHE } from "@/lib/types";

/**
 * The connected wallet's shares + earnings in this pool.
 *
 * REGISTRY pools (config/pools.ts): the share balance is read LIVE from the pool's
 * FeraShare ERC-20 on Robinhood Chain (with the value estimated pro-rata off
 * quoteNav/totalSupply); the API/mock positions feed only fills in what the chain
 * can't say cheaply (USD value, fees earned, pending esFERA — "—" until the indexer
 * serves them). Other pools keep the API/mock feed as before.
 */
export function YourPosition({
  pool,
  riskClass,
}: {
  pool: PoolSummary;
  riskClass?: RiskClass;
}) {
  const { address, isConnected } = useAccount();
  const live = livePoolById(pool.poolId);
  const { data: positions } = usePositions(address);
  const apiPos = positions?.find(
    (p) => p.poolId.toLowerCase() === pool.poolId.toLowerCase()
  );

  // Read-only use of the withdraw hook: live share balance, NAV, supply, last deposit.
  const chain = useVaultWithdraw(live);
  const chainShares =
    chain.shareBalance !== undefined
      ? Number(formatUnits(chain.shareBalance, 18))
      : undefined;
  const chainValueQuote =
    live &&
    chain.shareBalance !== undefined &&
    chain.navQuoteWei !== undefined &&
    chain.shareSupply !== undefined &&
    chain.shareSupply > 0n
      ? Number(
          formatUnits(
            (chain.shareBalance * chain.navQuoteWei) / chain.shareSupply,
            live.quoteDecimals
          )
        )
      : undefined;
  const chainLastAdd =
    chain.lastDepositTs !== undefined && chain.lastDepositTs > 0n
      ? Number(chain.lastDepositTs)
      : undefined;

  const hasChainPosition =
    !!live && chain.shareBalance !== undefined && chain.shareBalance > 0n;
  // Skeleton only while the FIRST read round-trip is in flight — if the RPC is
  // unreachable we degrade to the ordinary empty/API state instead of spinning forever.
  const chainLoading = !!live && isConnected && chain.readsPending && !apiPos;

  // The position we render/withdraw against: API row when the indexer knows it,
  // else a synthetic one from the live chain reads (the withdraw dialog re-reads
  // the chain itself, so the synthetic USD zeros are never displayed).
  const pos: Position | undefined =
    apiPos ??
    (hasChainPosition
      ? {
          poolId: pool.poolId,
          tranche: 0,
          shares: chainShares ?? 0,
          valueUsd: 0,
          feesEarned: 0,
          emissionsPending: "0",
          lastAddTs: chainLastAdd,
        }
      : undefined);
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
        ) : chainLoading ? (
          <div className="space-y-2">
            <Skeleton className="h-5 w-40" />
            <Skeleton className="h-5 w-56" />
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
                value={(live ? chainShares ?? pos.shares : pos.shares).toLocaleString(
                  "en-US",
                  { maximumFractionDigits: live ? 5 : 2 }
                )}
                tip="Fungible ERC-20 vault shares, usable across the chain's DeFi."
                sub={live ? "read on-chain" : undefined}
              />
              <Stat
                label="Value"
                value={
                  apiPos
                    ? usd(apiPos.valueUsd)
                    : chainValueQuote !== undefined && live
                    ? `≈ ${tokenAmt(chainValueQuote, 5)} ${live.quoteSymbol}`
                    : "—"
                }
                sub={!apiPos && live ? "pro-rata NAV" : undefined}
              />
              <Stat
                label="Fees earned"
                value={apiPos ? usd(apiPos.feesEarned) : "—"}
                accent="var(--pos)"
                sub={apiPos ? "net of 10% perf fee" : "arrives with the indexer"}
              />
              <Stat
                label="esFERA pending"
                value={apiPos ? esFera(apiPos.emissionsPending) : "—"}
                accent="var(--accent)"
                sub={apiPos ? "claim in Rewards" : "arrives with the indexer"}
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
