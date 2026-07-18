"use client";

import { useEffect, useState } from "react";
import { useAccount } from "wagmi";
import { formatUnits } from "viem";
import { Modal } from "@/components/ui/Modal";
import { Button } from "@/components/ui/Button";
import { RegimeBadge } from "@/components/ui/Badge";
import { TokenPair } from "@/components/ui/TokenPair";
import { JitPenaltyNotice } from "./JitPenaltyNotice";
import { AmountField } from "./AmountField";
import { useVaultWithdraw, txBusy } from "@/lib/hooks/useVaultTx";
import { parseAmount } from "@/lib/amount";
import { livePoolById, type LivePool } from "@/config/pools";
import { EXPLORER_TX } from "@/config/chains";
import { holdState, windowCountdown, HOLD_LABEL } from "@/lib/jit";
import { usd, esFera, tokenAmt } from "@/lib/format";
import type { PoolSummary, Position } from "@/lib/types";

/**
 * Withdraw dialog. Withdrawals are in-kind and pro-rata — you get your share of the actual
 * pool tokens, with no pricing — and are never blocked once the one-time 1-hour post-deposit
 * hold has passed (lib/jit#DEPOSIT_HOLD_SEC).
 *
 * REGISTRY pools (config/pools.ts) send a REAL FeraVault.withdraw(id, tranche, shares,
 * minAmount0, minAmount1) on Robinhood Chain: the share balance, the hold (the vault's
 * on-chain lastDepositTs + 1h cooldown) and the pro-rata value estimate are all read
 * from the contracts. Other pools keep the original mocked preview.
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
  const live = livePoolById(pool.poolId);

  function reset() {
    setOpen(false);
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
          {live ? (
            /* REAL on-chain withdraw (Modal unmounts on close, so tx state resets). */
            <LiveWithdrawBody live={live} onClose={reset} />
          ) : (
            <MockWithdrawBody pool={pool} position={position} onClose={reset} />
          )}
        </div>
      </Modal>
    </>
  );
}

/** Proportional in-kind withdraw against the live vault (tranche 0 — see useVaultTx). */
function LiveWithdrawBody({ live, onClose }: { live: LivePool; onClose: () => void }) {
  const { isConnected } = useAccount();
  const w = useVaultWithdraw(live, 0);
  const [amt, setAmt] = useState("");

  // Tick while open so the live hold countdown / disabled state stays honest.
  const [, force] = useState(0);
  useEffect(() => {
    const id = setInterval(() => force((n) => n + 1), 1000);
    return () => clearInterval(id);
  }, []);

  const sharesWei = parseAmount(amt, 18); // FeraShare is fixed 18-dec
  const over =
    sharesWei !== null && w.shareBalance !== undefined && sharesWei > w.shareBalance;

  // REAL hold: the vault reverts CooldownActive before lastDepositTs + 1h.
  const lastAdd =
    w.lastDepositTs !== undefined && w.lastDepositTs > 0n
      ? Number(w.lastDepositTs)
      : undefined;
  const h = holdState(lastAdd);
  const busy = txBusy(w.phase);

  // Pro-rata value estimate in quote terms: shares × NAV / totalSupply (display only).
  const estQuote =
    sharesWei !== null &&
    sharesWei > 0n &&
    w.navQuoteWei !== undefined &&
    w.shareSupply !== undefined &&
    w.shareSupply > 0n
      ? Number(formatUnits((sharesWei * w.navQuoteWei) / w.shareSupply, live.quoteDecimals))
      : undefined;
  const balanceNum =
    w.shareBalance !== undefined ? Number(formatUnits(w.shareBalance, 18)) : undefined;

  const canConfirm =
    isConnected &&
    sharesWei !== null &&
    sharesWei > 0n &&
    !over &&
    !h.held &&
    !busy;

  const buttonLabel = () => {
    switch (w.phase.step) {
      case "wallet":
        return "Confirm in wallet…";
      case "tx":
        return "Withdrawing…";
      case "error":
        return "Try again";
      default:
        if (h.held) return `Withdraw in ${windowCountdown(h.secondsLeft)}`;
        if (over) return "Not enough shares";
        return "Confirm withdraw";
    }
  };

  if (w.phase.step === "success") {
    return (
      <div className="space-y-3 py-2 text-center">
        <div className="mx-auto grid h-12 w-12 place-items-center rounded-full bg-pos-wash text-pos text-xl">
          ✓
        </div>
        <p className="text-body text-text">
          Withdrawn from {live.symbol}/{live.quoteSymbol} — in-kind, straight from the
          pool.
        </p>
        <a
          href={EXPLORER_TX(w.phase.hash)}
          target="_blank"
          rel="noreferrer"
          className="inline-block text-caption font-medium text-accent2 hover:underline"
        >
          View transaction on Blockscout ↗
        </a>
        <Button className="w-full" onClick={onClose}>
          Done
        </Button>
      </div>
    );
  }

  return (
    <>
      <div className="grid grid-cols-2 gap-2 rounded-lg border border-line bg-card p-3 text-center">
        <div>
          <div className="overline mb-1">Your shares</div>
          <div className="font-mono tnum text-body-sm font-semibold text-text">
            {balanceNum !== undefined ? tokenAmt(balanceNum, 5) : "—"}
          </div>
        </div>
        <div>
          <div className="overline mb-1">You&apos;d receive ≈</div>
          <div className="font-mono tnum text-body-sm font-semibold text-text">
            {estQuote !== undefined
              ? `${tokenAmt(estQuote, 5)} ${live.quoteSymbol}`
              : "—"}
          </div>
        </div>
      </div>

      <AmountField
        label="Shares to withdraw"
        symbol="shares"
        decimals={18}
        value={amt}
        onChange={setAmt}
        balance={w.shareBalance}
        error={over}
        disabled={busy}
      />

      {/* one-time post-deposit hold status (REAL, from the vault's lastDepositTs) */}
      <JitPenaltyNotice mode="withdraw" lastAddTs={lastAdd} />

      <p className="text-caption text-mute">
        Withdrawals are in-kind and pro-rata — you get your share of the actual pool
        tokens ({live.symbol} and {live.quoteSymbol}), with no pricing — and are never
        blocked once the {HOLD_LABEL} hold has passed. The estimate above values your
        share in {live.quoteSymbol} terms; the tokens arrive in both assets.
      </p>

      {w.phase.step === "error" ? (
        <div className="rounded-lg border border-danger-line bg-danger-wash p-3 text-body-sm text-text">
          {w.phase.message}
        </div>
      ) : null}

      {w.phase.step === "tx" ? (
        <p className="text-center text-caption text-mute">
          <a
            href={EXPLORER_TX(w.phase.hash)}
            target="_blank"
            rel="noreferrer"
            className="font-medium text-accent2 hover:underline"
          >
            Track on Blockscout ↗
          </a>
        </p>
      ) : null}

      <Button
        className="w-full"
        size="lg"
        disabled={!canConfirm}
        onClick={() => {
          if (sharesWei === null || sharesWei === 0n) return;
          void w.submit(sharesWei);
        }}
      >
        {buttonLabel()}
      </Button>
    </>
  );
}

/** Original mocked preview for non-registry (fixture) pools — behavior unchanged. */
function MockWithdrawBody({
  pool,
  position,
  onClose,
}: {
  pool: PoolSummary;
  position: Position;
  onClose: () => void;
}) {
  const [submitting, setSubmitting] = useState(false);
  const [done, setDone] = useState(false);

  // Tick while open so the live hold countdown / disabled state stays honest.
  const [, force] = useState(0);
  useEffect(() => {
    const id = setInterval(() => force((n) => n + 1), 1000);
    return () => clearInterval(id);
  }, []);

  // A withdrawal is only ever held back by the one-time post-deposit hold — never otherwise.
  const h = holdState(position.lastAddTs);
  const canConfirm = !h.held;

  if (done) {
    return (
      <div className="space-y-3 py-2 text-center">
        <div className="mx-auto grid h-12 w-12 place-items-center rounded-full bg-pos-wash text-pos text-xl">
          ✓
        </div>
        <p className="text-body text-text">
          Withdrawn from {pool.token0.symbol}/{pool.token1.symbol}.
        </p>
        <Button className="w-full" onClick={onClose}>
          Done
        </Button>
      </div>
    );
  }

  return (
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
      <JitPenaltyNotice mode="withdraw" lastAddTs={position.lastAddTs} />

      <p className="text-caption text-mute">
        Withdrawals are in-kind and pro-rata — you get your share of the actual pool
        tokens, with no pricing — and are never blocked once the {HOLD_LABEL} hold has
        passed. Any pending esFERA keeps vesting; withdrawing shares doesn&apos;t
        forfeit it.
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
          ? `Withdraw in ${windowCountdown(h.secondsLeft)}`
          : "Confirm withdraw"}
      </Button>
    </>
  );
}
