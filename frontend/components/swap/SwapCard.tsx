"use client";

import { useMemo, useState } from "react";
import { useAccount } from "wagmi";
import { usePools, usePool } from "@/lib/hooks/useApi";
import { useLiveFee } from "@/lib/hooks/useLiveFee";
import { feeReason, TONE_COLOR } from "@/lib/feeReason";
import { Card, CardHeader } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { Skeleton } from "@/components/ui/Skeleton";
import { LiveDot } from "@/components/ui/LiveDot";
import { RegimeBadge } from "@/components/ui/Badge";
import { InfoTip } from "@/components/ui/InfoTip";
import { feePipsToPct, feePipsToFraction, tokenAmt } from "@/lib/format";
import type { PoolId } from "@/lib/types";

/** PEPE/WETH MEME pool, the elevated-vol default so the fee reason is legible. */
const DEFAULT_POOL: PoolId =
  "0x0000000000000000000000000000000000000000000000000000000000000002";

/**
 * Minimal router-backed swap. Swaps are permissionless and pay the protocol NOTHING
 * (INV-2): the LP fee shown is the dynamic regime fee, and it accrues entirely to LPs.
 * The card's whole job is honesty about that live fee: it prints the number AND the
 * reason ("fee is 2.10%: volatility elevated" / "fee widened: market closed").
 */
export function SwapCard() {
  const { data: pools } = usePools();
  const { isConnected } = useAccount();
  const [poolId, setPoolId] = useState<PoolId>(DEFAULT_POOL);
  const [amount, setAmount] = useState("100");
  const [swapped, setSwapped] = useState(false);

  const pool = pools?.find((p) => p.poolId === poolId) ?? pools?.[0];
  // pool detail carries marketHoursState (RWA) so the reason is exact.
  const { data: detail } = usePool(pool?.poolId ?? DEFAULT_POOL);

  const { pips } = useLiveFee(pool?.currentFeePips ?? 3000, pool?.regime ?? "MEME");
  const reason = useMemo(
    () =>
      pool
        ? feeReason(pool.regime, pips, detail?.marketHoursState ?? null)
        : null,
    [pool, pips, detail]
  );

  if (!pool || !pools) return <Skeleton className="h-96 w-full rounded-lg" />;

  const amtIn = Number(amount) || 0;
  const feeFraction = feePipsToFraction(pips); // pips → decimal (30000 → 0.03)
  const lpFee = amtIn * feeFraction; // charged in the input token, goes to LPs
  const received = amtIn - lpFee; // net of the LP fee (pre-price, 1:1 illustrative)

  return (
    <Card className="overflow-hidden">
      <CardHeader
        eyebrow="Swap"
        title="Router-backed swap"
        action={<LiveDot label="LIVE FEE" />}
      />

      <div className="px-5 pb-5 space-y-4">
        {/* pool / pair selector */}
        <label className="block">
          <span className="overline">Market</span>
          <div className="mt-1 flex items-center gap-2 rounded-lg border border-line bg-surface px-3 py-2.5 focus-within:border-accent-line">
            <select
              value={poolId}
              onChange={(e) => {
                setPoolId(e.target.value as PoolId);
                setSwapped(false);
              }}
              className="w-full bg-transparent text-body text-text outline-none"
              aria-label="Select market"
            >
              {pools.map((p) => (
                <option key={p.poolId} value={p.poolId} className="bg-raised">
                  {p.token0.symbol} / {p.token1.symbol} · {p.regime}
                </option>
              ))}
            </select>
            <RegimeBadge regime={pool.regime} />
          </div>
        </label>

        {/* amount in */}
        <label className="block">
          <span className="overline">You pay</span>
          <div className="mt-1 flex items-center gap-2 rounded-lg border border-line bg-surface px-3 py-2.5 focus-within:border-accent-line">
            <input
              inputMode="decimal"
              placeholder="0.00"
              value={amount}
              onChange={(e) => {
                setAmount(e.target.value.replace(/[^0-9.]/g, ""));
                setSwapped(false);
              }}
              className="w-full bg-transparent font-mono tnum text-title outline-none placeholder:text-mute"
            />
            <span className="text-body-sm text-dim">{pool.token0.symbol}</span>
          </div>
        </label>

        {/* the live regime fee + WHY, the core of the page */}
        {reason ? (
          <div
            className="rounded-lg border p-4"
            style={{
              borderColor: "var(--line)",
              background: "var(--ink-900)",
            }}
          >
            <div className="flex items-center justify-between">
              <span className="overline">Live regime fee</span>
              <span
                className="font-mono tnum text-title font-semibold"
                style={{ color: TONE_COLOR[reason.tone] }}
              >
                {feePipsToPct(pips)}
              </span>
            </div>
            <div className="mt-2 flex items-start gap-2">
              <span
                className="mt-1.5 h-2 w-2 shrink-0 rounded-full"
                style={{ background: TONE_COLOR[reason.tone] }}
              />
              <div>
                <div
                  className="text-body font-medium"
                  style={{ color: TONE_COLOR[reason.tone] }}
                >
                  {reason.headline}
                </div>
                <p className="mt-0.5 text-body-sm text-dim">{reason.detail}</p>
              </div>
            </div>
          </div>
        ) : null}

        {/* quote rows */}
        <div className="rounded-lg border border-line bg-card p-3 text-body-sm">
          <Row
            label="LP fee"
            tip="The dynamic fee, charged in the input token. It goes 100% to LPs. The protocol takes nothing from swaps (INV-2)."
            value={`${tokenAmt(lpFee, 4)} ${pool.token0.symbol}`}
          />
          <Row
            label="Est. received"
            value={`${tokenAmt(received, 4)} ${pool.token1.symbol}`}
            sub="net of LP fee · illustrative 1:1"
          />
          <Row
            label="Route"
            value="Universal Router → FERA v4"
            sub="flagless hook, routers reach it permissionlessly"
          />
        </div>

        <Button
          className="w-full"
          size="lg"
          disabled={amtIn <= 0 || swapped}
          onClick={() => setSwapped(true)}
        >
          {swapped ? "Swapped ✓ (preview)" : isConnected ? "Swap" : "Swap (preview)"}
        </Button>

        <p className="text-caption text-mute">
          Traders pay the protocol nothing. The fee above is the regime fee that
          accrues to LPs; it is never a protocol take. Swapping is never gated or
          paused (INV-2 / INV-11).
        </p>
      </div>
    </Card>
  );
}

function Row({
  label,
  value,
  sub,
  tip,
}: {
  label: string;
  value: string;
  sub?: string;
  tip?: string;
}) {
  return (
    <div className="flex items-start justify-between gap-4 py-1.5">
      <span className="flex items-center gap-1 text-mute">
        {label}
        {tip ? <InfoTip text={tip} /> : null}
      </span>
      <span className="text-right">
        <span className="font-mono tnum text-text">{value}</span>
        {sub ? <span className="block text-caption text-mute">{sub}</span> : null}
      </span>
    </div>
  );
}
