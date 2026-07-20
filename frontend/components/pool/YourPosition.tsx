"use client";

import { useAccount } from "wagmi";
import { formatUnits } from "viem";
import type { PoolSummary, Position, RiskClass } from "@/lib/types";
import { usePositions } from "@/lib/hooks/useApi";
import { useVaultWithdraw } from "@/lib/hooks/useVaultTx";
import { livePoolById, type LivePool } from "@/config/pools";
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
 * The connected wallet's shares + earnings in this pool — for BOTH risk classes.
 *
 * REGISTRY pools (config/pools.ts) always have both tranches initialized on-chain
 * (`createBaseLimitPool` seeds both at pool creation), so both are read live here —
 * a real tranche-1 ("Active"/Core) position is never invisible just because the
 * indexer hasn't caught up on it yet. The share balance/NAV/supply for each tranche
 * come straight from the chain (with the value estimated pro-rata off
 * quoteNav/totalSupply); the API/mock positions feed only fills in what the chain
 * can't say cheaply (USD value, fees earned, pending esFERA — "—" until the indexer
 * serves them). Non-registry (fixture) pools keep the original single API-row
 * behavior — they have no on-chain tranche 1 to read.
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
  const poolPositions =
    positions?.filter((p) => p.poolId.toLowerCase() === pool.poolId.toLowerCase()) ?? [];
  const apiPosByTranche = (t: number) => poolPositions.find((p) => (p.tranche ?? 0) === t);

  // Read-only use of the withdraw hook, once per tranche: live share balance, NAV,
  // supply, last deposit. Cheap even for fixture pools (`live` undefined ⇒ every
  // value stays undefined, no chain reads fire).
  const chain0 = useVaultWithdraw(live, 0);
  const chain1 = useVaultWithdraw(live, 1);

  const view0 = buildTrancheView(pool, live, 0, apiPosByTranche(0), chain0);
  const view1 = buildTrancheView(pool, live, 1, apiPosByTranche(1), chain1);
  const views = [view0, view1];
  const held = views.filter((v) => v.pos);

  // Skeleton only while the FIRST read round-trip is in flight and neither tranche
  // has an API-known position to show meanwhile — if the RPC is unreachable we
  // degrade to the ordinary empty/API state instead of spinning forever.
  const chainLoading =
    !!live && isConnected && (chain0.readsPending || chain1.readsPending) && !held.length;

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
        ) : !held.length ? (
          <div className="flex flex-col items-start gap-3">
            <p className="text-body-sm text-dim">
              You&apos;re not providing to this pool yet.
            </p>
            <DepositDialog pool={pool} defaultRiskClass={riskClass} />
          </div>
        ) : (
          <div className="space-y-5">
            {held.map((tv, i) => (
              <div key={tv.tranche} className={i > 0 ? "border-t border-line pt-5" : undefined}>
                <TrancheBlock pool={pool} live={live} view={tv} riskClass={riskClass} />
              </div>
            ))}
          </div>
        )}
      </div>
    </Card>
  );
}

/** One risk class's resolved position — API row wins per-tranche, chain fills the rest. */
interface TrancheView {
  tranche: number;
  riskClass: RiskClass;
  apiPos?: Position;
  chainShares?: number;
  chainValueQuote?: number;
  pos?: Position;
}

function buildTrancheView(
  pool: PoolSummary,
  live: LivePool | undefined,
  tranche: number,
  apiPos: Position | undefined,
  chain: ReturnType<typeof useVaultWithdraw>,
): TrancheView {
  const chainShares =
    chain.shareBalance !== undefined ? Number(formatUnits(chain.shareBalance, 18)) : undefined;
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
  const hasChainPosition = !!live && chain.shareBalance !== undefined && chain.shareBalance > 0n;

  // The position we render/withdraw against: API row when the indexer knows it, else a
  // synthetic one from the live chain reads (the withdraw dialog re-reads the chain
  // itself, so the synthetic USD zeros are never displayed).
  const pos: Position | undefined =
    apiPos ??
    (hasChainPosition
      ? {
          poolId: pool.poolId,
          tranche,
          shares: chainShares ?? 0,
          valueUsd: 0,
          feesEarned: 0,
          emissionsPending: "0",
          lastAddTs: chainLastAdd,
        }
      : undefined);

  return {
    tranche,
    riskClass: RISK_CLASS_BY_TRANCHE[tranche] ?? "CORE",
    apiPos,
    chainShares,
    chainValueQuote,
    pos,
  };
}

function TrancheBlock({
  pool,
  live,
  view,
  riskClass,
}: {
  pool: PoolSummary;
  live: LivePool | undefined;
  view: TrancheView;
  riskClass?: RiskClass;
}) {
  const { pos, apiPos, chainShares, chainValueQuote } = view;
  if (!pos) return null;
  const meta = RISK_CLASS_META[view.riskClass];

  return (
    <>
      <div className="mb-3 inline-flex items-center gap-1.5 rounded-full border border-line bg-well px-2 py-0.5 text-caption">
        <span className="h-1.5 w-1.5 rounded-full" style={{ background: meta.color }} />
        <span className="text-dim">{meta.label} profile</span>
      </div>
      <div className="grid grid-cols-2 gap-5 sm:grid-cols-4">
        <Stat
          label="Vault shares"
          value={(live ? chainShares ?? pos.shares : pos.shares).toLocaleString("en-US", {
            maximumFractionDigits: live ? 5 : 2,
          })}
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
          defaultRiskClass={view.riskClass ?? riskClass}
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
  );
}
