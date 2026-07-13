"use client";

import { useState } from "react";
import { Modal } from "@/components/ui/Modal";
import { Button } from "@/components/ui/Button";
import { RegimeBadge } from "@/components/ui/Badge";
import { TokenPair } from "@/components/ui/TokenPair";
import { JitPenaltyNotice } from "./JitPenaltyNotice";
import { jitState } from "@/lib/jit";
import { usd, esFera } from "@/lib/format";
import type { PoolSummary, Position } from "@/lib/types";

/**
 * Withdraw dialog. Its whole reason to exist beyond a plain "burn shares" flow is to make the
 * early-exit fee-forfeiture penalty (INV-1″ / D-14) impossible to miss BEFORE confirm — the
 * same rigor as the esFERA instant-exit haircut. If the position is inside its JIT window the
 * user sees, live, exactly how much accrued fee they'd forfeit and must tick an ack.
 */
export function WithdrawDialog({
  pool,
  position,
  trigger,
}: {
  pool: PoolSummary;
  position: Position;
  trigger: (open: () => void) => React.ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const [ack, setAck] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [done, setDone] = useState(false);

  const s = jitState(pool.regime, position.lastAddTs);
  // Only force the explicit forfeiture ack while the penalty is actually live.
  const needsAck = s.active && position.feesEarned > 0;
  const canConfirm = !needsAck || ack;

  function reset() {
    setOpen(false);
    setTimeout(() => {
      setAck(false);
      setDone(false);
    }, 200);
  }

  return (
    <>
      {trigger(() => setOpen(true))}
      <Modal open={open} onClose={reset} title="Withdraw liquidity">
        <div className="p-5 space-y-4">
          <div className="flex items-center justify-between">
            <TokenPair token0={pool.token0} token1={pool.token1} />
            <RegimeBadge regime={pool.regime} />
          </div>

          {done ? (
            <div className="space-y-3 py-2 text-center">
              <div className="mx-auto grid h-12 w-12 place-items-center rounded-full bg-pos-wash text-pos text-xl">
                ✓
              </div>
              <p className="text-body text-text">
                Withdrawn from {pool.token0.symbol}/{pool.token1.symbol}.
              </p>
              <Button className="w-full" onClick={reset}>
                Done
              </Button>
            </div>
          ) : (
            <>
              <div className="grid grid-cols-3 gap-2 rounded-lg border border-line bg-card p-3 text-center">
                <div>
                  <div className="overline mb-1">Position</div>
                  <div className="font-mono tnum text-body-sm font-semibold text-text">
                    {usd(position.valueUsd)}
                  </div>
                </div>
                <div>
                  <div className="overline mb-1">Fees earned</div>
                  <div className="font-mono tnum text-body-sm font-semibold text-pos">
                    {usd(position.feesEarned)}
                  </div>
                </div>
                <div>
                  <div className="overline mb-1">esFERA</div>
                  <div className="font-mono tnum text-body-sm font-semibold text-accent">
                    {esFera(position.emissionsPending)}
                  </div>
                </div>
              </div>

              {/* the whole point: JIT forfeiture, surfaced before confirm */}
              <JitPenaltyNotice
                regime={pool.regime}
                mode="withdraw"
                lastAddTs={position.lastAddTs}
                accruedFeesUsd={position.feesEarned}
              />

              <p className="text-caption text-mute">
                Principal is returned in full and a withdrawal is never blocked (INV-11). Any
                pending esFERA keeps vesting — withdrawing shares doesn&apos;t forfeit it.
              </p>

              {needsAck ? (
                <label className="flex items-start gap-2 rounded-lg border border-danger-line bg-danger-wash p-3 text-body-sm text-text">
                  <input
                    type="checkbox"
                    checked={ack}
                    onChange={(e) => setAck(e.target.checked)}
                    className="mt-0.5 accent-[var(--danger)]"
                  />
                  <span>
                    I understand I&apos;m forfeiting accrued fees by exiting inside the{" "}
                    early-exit window.
                  </span>
                </label>
              ) : null}

              <Button
                className="w-full"
                size="lg"
                variant={needsAck ? "danger" : "primary"}
                disabled={!canConfirm || submitting}
                onClick={() => {
                  setSubmitting(true);
                  setTimeout(() => {
                    setSubmitting(false);
                    setDone(true);
                  }, 800);
                }}
              >
                {submitting
                  ? "Confirming…"
                  : needsAck
                  ? "Withdraw & forfeit fees"
                  : "Confirm withdraw"}
              </Button>
            </>
          )}
        </div>
      </Modal>
    </>
  );
}
