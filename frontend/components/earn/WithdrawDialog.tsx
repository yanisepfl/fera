"use client";

import { useEffect, useState } from "react";
import { Modal } from "@/components/ui/Modal";
import { Button } from "@/components/ui/Button";
import { RegimeBadge } from "@/components/ui/Badge";
import { TokenPair } from "@/components/ui/TokenPair";
import { JitPenaltyNotice } from "./JitPenaltyNotice";
import { holdState, windowCountdown, HOLD_LABEL } from "@/lib/jit";
import { usd, esFera } from "@/lib/format";
import type { PoolSummary, Position } from "@/lib/types";

/**
 * Withdraw dialog. Withdrawals are ASYNC (ERC-7540-style): you REQUEST now and the position
 * becomes claimable after a 24-hour safety delay, then settles in-kind and pro-rata — your share
 * of the actual pool tokens, with no pricing. A one-time 1-hour post-deposit hold gates when you
 * can request (lib/jit#DEPOSIT_HOLD_SEC); while a fresh position is inside it the confirm is held
 * back with a live countdown. (The two-step request → claim UI lands with the on-chain wiring.)
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
  const [submitting, setSubmitting] = useState(false);
  const [done, setDone] = useState(false);

  // Tick while open so the live hold countdown / disabled state stays honest.
  const [, force] = useState(0);
  useEffect(() => {
    if (!open) return;
    const id = setInterval(() => force((n) => n + 1), 1000);
    return () => clearInterval(id);
  }, [open]);

  // A withdrawal is only ever held back by the one-time post-deposit hold — never otherwise.
  const h = holdState(position.lastAddTs);
  const canConfirm = !h.held;

  function reset() {
    setOpen(false);
    setTimeout(() => {
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
                Withdrawal requested from {pool.token0.symbol}/{pool.token1.symbol}. It&apos;ll
                be claimable in 24 hours, in-kind and pro-rata.
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

              {/* one-time post-deposit hold status, surfaced before confirm */}
              <JitPenaltyNotice
                mode="withdraw"
                lastAddTs={position.lastAddTs}
              />

              <p className="text-caption text-mute">
                You request now; the position becomes claimable after a 24-hour safety delay,
                then settles in-kind and pro-rata — your share of the actual pool tokens, with no
                pricing. Any pending esFERA keeps vesting; withdrawing shares doesn&apos;t forfeit
                it.
              </p>

              <Button
                className="w-full"
                size="lg"
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
                  : h.held
                  ? `Request in ${windowCountdown(h.secondsLeft)}`
                  : "Request withdrawal"}
              </Button>
            </>
          )}
        </div>
      </Modal>
    </>
  );
}
