"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { Modal } from "@/components/ui/Modal";
import { Button } from "@/components/ui/Button";
import { RegimeBadge } from "@/components/ui/Badge";
import { TokenPair } from "@/components/ui/TokenPair";
import { RiskClassSelector } from "@/components/pool/RiskClassSelector";
import { JitPenaltyNotice } from "./JitPenaltyNotice";
import { useGeoFence } from "@/lib/hooks/useGeoFence";
import { apr, usdCompact, feePipsToPct } from "@/lib/format";
import { RISK_CLASS_META, availableRiskClasses } from "@/lib/riskClass";
import type { PoolSummary, RiskClass } from "@/lib/types";

/**
 * 2-click deposit:  [Deposit] → set amount + Confirm.
 * RWA pools pass through the config-driven geo-fence (config/geo.ts): blocked
 * regions can't deposit; ack regions must tick a risk box first. Swaps are never
 * gated by this (INV-2); only the LP affordance is.
 */
export function DepositDialog({
  pool,
  trigger,
  defaultRiskClass = "CORE",
}: {
  pool: PoolSummary;
  trigger?: (open: () => void) => React.ReactNode;
  /** Pre-select a risk profile (e.g. the one chosen on the Pool page). */
  defaultRiskClass?: RiskClass;
}) {
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState("");
  const [acked, setAcked] = useState(false);
  const [riskClass, setRiskClass] = useState<RiskClass>(defaultRiskClass);
  const [submitting, setSubmitting] = useState(false);
  const [done, setDone] = useState(false);
  const { isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const geo = useGeoFence(pool.regime);

  // Per-class APR when the pool carries risk-class data; else the whole-pool blend.
  const classes: { riskClass: RiskClass; feeApr: number; emissionsApr: number }[] =
    pool.tranches && pool.tranches.length
      ? pool.tranches
      : availableRiskClasses(pool.regime).map((rc) => ({
          riskClass: rc,
          feeApr: pool.feeApr,
          emissionsApr: pool.emissionsApr,
        }));
  const selected =
    classes.find((t) => t.riskClass === riskClass) ?? classes[0];
  const feeAprSel = selected.feeApr;
  const emissionsAprSel = selected.emissionsApr;
  const totalApr = feeAprSel + emissionsAprSel;

  const canConfirm =
    !!amount &&
    Number(amount) > 0 &&
    !geo.blocked &&
    (!geo.needsAck || acked);

  function confirm() {
    setSubmitting(true);
    // Mocked tx. Real path: Vault.deposit(poolId, amounts) via wagmi useWriteContract.
    setTimeout(() => {
      setSubmitting(false);
      setDone(true);
    }, 900);
  }

  function reset() {
    setOpen(false);
    setTimeout(() => {
      setAmount("");
      setAcked(false);
      setRiskClass(defaultRiskClass);
      setDone(false);
    }, 200);
  }

  return (
    <>
      {trigger ? (
        trigger(() => setOpen(true))
      ) : (
        <Button size="sm" onClick={() => setOpen(true)}>
          Deposit
        </Button>
      )}

      <Modal open={open} onClose={reset} title="Deposit liquidity">
        <div className="p-5 space-y-4">
          <div className="flex items-center justify-between">
            <TokenPair token0={pool.token0} token1={pool.token1} />
            <RegimeBadge regime={pool.regime} />
          </div>

          {pool.vaultLive === false ? (
            /* PRE-LAUNCH: the vault contract isn't deployed — no deposit exists to make.
               The market data shown elsewhere is real; nothing accrues yet. */
            <div className="space-y-3">
              <div className="rounded-lg border border-line bg-well p-3 text-body-sm text-dim">
                <span className="font-semibold text-text">Deposits open at launch.</span>{" "}
                The vault for this market isn&apos;t deployed yet. Prices and volume you
                see are the live market it will run — vault deposits, fees and FERA
                rewards start when the contracts go live.
              </div>
              <Button className="w-full" onClick={reset}>
                Got it
              </Button>
            </div>
          ) : geo.blocked ? (
            <div className="rounded-lg border border-danger-line bg-danger-wash p-3 text-body-sm text-text">
              {geo.reason} Swapping remains permissionless everywhere.
            </div>
          ) : done ? (
            <div className="space-y-3 py-2 text-center">
              <div className="mx-auto grid h-12 w-12 place-items-center rounded-full bg-pos-wash text-pos text-xl">
                ✓
              </div>
              <p className="text-body text-text">
                Deposited into {pool.token0.symbol}/{pool.token1.symbol} ·{" "}
                <span style={{ color: RISK_CLASS_META[riskClass].color }}>
                  {RISK_CLASS_META[riskClass].label}
                </span>
                .
              </p>
              <p className="text-caption text-mute">
                You now hold vault shares. Your trading fees and FERA rewards build up in
                them automatically.
              </p>
              <Button className="w-full" onClick={reset}>
                Done
              </Button>
            </div>
          ) : (
            <>
              {/* amount */}
              <label className="block">
                <span className="overline">Amount</span>
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
                  <span className="text-body-sm text-dim">
                    {pool.token1.symbol}
                  </span>
                </div>
              </label>

              {/* risk-profile selector (D-12 / D-16; user-facing terms per D-18) */}
              <RiskClassSelector
                pool={pool}
                value={riskClass}
                onChange={setRiskClass}
                variant="compact"
              />

              {/* APY split preview: fee yield vs emissions, for the CHOSEN profile */}
              <div className="grid grid-cols-3 gap-2 rounded-lg border border-line bg-card p-3 text-center">
                <div>
                  <div className="overline mb-1">Fee APR</div>
                  <div className="font-mono tnum text-body font-semibold text-pos">
                    {apr(feeAprSel)}
                  </div>
                </div>
                <div>
                  <div className="overline mb-1">Emissions</div>
                  <div className="font-mono tnum text-body font-semibold text-accent">
                    {apr(emissionsAprSel)}
                  </div>
                </div>
                <div>
                  <div className="overline mb-1">Total</div>
                  <div className="font-mono tnum text-body font-semibold text-text">
                    {apr(totalApr)}
                  </div>
                </div>
              </div>

              <p className="text-caption text-mute">
                Live fee {feePipsToPct(pool.currentFeePips)} · TVL{" "}
                {usdCompact(pool.tvlUsd)} · a performance fee applies only to the fees you
                earn, never to your deposit.
              </p>

              {/* one-time post-deposit hold, surfaced before confirm */}
              <JitPenaltyNotice mode="deposit" />

              {geo.needsAck ? (
                <label className="flex items-start gap-2 rounded-lg border border-warn-wash bg-warn-wash p-3 text-body-sm text-dim">
                  <input
                    type="checkbox"
                    checked={acked}
                    onChange={(e) => setAcked(e.target.checked)}
                    className="mt-0.5 accent-[var(--accent2)]"
                  />
                  <span>
                    {geo.reason} I understand the risk of providing to a stock-token pool
                    and confirm eligibility.
                  </span>
                </label>
              ) : null}

              {!isConnected ? (
                <Button
                  className="w-full"
                  size="lg"
                  onClick={() => openConnectModal?.()}
                >
                  Connect wallet to deposit
                </Button>
              ) : (
                <Button
                  className="w-full"
                  size="lg"
                  disabled={!canConfirm || submitting}
                  onClick={confirm}
                >
                  {submitting ? "Confirming…" : "Confirm deposit"}
                </Button>
              )}
            </>
          )}
        </div>
      </Modal>
    </>
  );
}
