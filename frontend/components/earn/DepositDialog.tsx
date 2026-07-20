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
import { AmountField } from "./AmountField";
import { useGeoFence, type GeoFenceResult } from "@/lib/hooks/useGeoFence";
import { useRwaComplianceGate } from "@/lib/hooks/useRwaComplianceGate";
import { useVaultDeposit, txBusy } from "@/lib/hooks/useVaultTx";
import { useDepositGate } from "@/lib/hooks/useDepositGate";
import { parseAmount } from "@/lib/amount";
import { livePoolById, type LivePool } from "@/config/pools";
import { EXPLORER_TX } from "@/config/chains";
import { apr, usdCompact, feePipsToPct, tokenAmt } from "@/lib/format";
import { RISK_CLASS_META, availableRiskClasses } from "@/lib/riskClass";
import type { PoolSummary, RiskClass } from "@/lib/types";

/**
 * 2-click deposit:  [Deposit] → set amount + Confirm.
 *
 * TWO paths behind one dialog:
 *  - REGISTRY pools (config/pools.ts — deployed on Robinhood Chain 4663): REAL
 *    transactions. Balances/allowances are read on-chain; each nonzero side gets an
 *    exact-amount ERC-20 approve if short; then FeraVault.deposit(id, tranche,
 *    amount0, amount1, minShares) in the pool's true token0/token1 order.
 *  - anything else (fixture/mock pools): the original mocked preview, unchanged.
 *
 * RWA pools pass through the config-driven geo-fence (config/geo.ts): blocked
 * regions can't deposit; ack regions must tick a risk box first. Swaps are never
 * gated by this (INV-2); only the LP affordance is.
 *
 * That geo-fence is only the fast, Tier-1 pass (see config/geo.ts). Right before an
 * RWA deposit actually executes, `confirm()` also fires the Tier-2 server-side gate
 * (lib/hooks/useRwaComplianceGate.ts → lib/compliance/decision.ts): VPN/Tor detection
 * and wallet-sanctions screening on top of the country check. This never runs for MEME
 * pools (guarded by `pool.regime === "RWA"` below) — MEME deposits are unaffected.
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
  const [complianceBlock, setComplianceBlock] = useState<string | null>(null);
  const { isConnected, address } = useAccount();
  const { openConnectModal } = useConnectModal();
  const geo = useGeoFence(pool.regime);
  const rwaGate = useRwaComplianceGate();
  const live = livePoolById(pool.poolId);

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
    (!geo.needsAck || acked) &&
    !rwaGate.checking;

  async function confirm() {
    setComplianceBlock(null);
    setSubmitting(true);
    // Tier-2 authoritative gate — RWA only (see file header). MEME pools skip this
    // branch entirely: zero added network calls / logic for them.
    if (pool.regime === "RWA") {
      const verdict = await rwaGate.run(address ?? "");
      if (verdict.decision === "block") {
        setComplianceBlock(verdict.reason);
        setSubmitting(false);
        return;
      }
    }
    // Mocked tx (non-registry pools only — registry pools go through LiveDepositBody).
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
      setComplianceBlock(null);
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

          {pool.vaultLive === false && !live ? (
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
          ) : live ? (
            /* REAL on-chain deposit path (Modal unmounts on close, so tx state resets). */
            <LiveDepositBody
              pool={pool}
              live={live}
              riskClass={riskClass}
              setRiskClass={setRiskClass}
              geo={geo}
              acked={acked}
              setAcked={setAcked}
              onClose={reset}
            />
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

              {/* Tier-2 gate verdict (RWA only — see confirm()). Distinct from the geo
                  banner above: this fires only at confirm time, from checks a country
                  code alone can't make (VPN/Tor, wallet sanctions). */}
              {complianceBlock ? (
                <div className="rounded-lg border border-danger-line bg-danger-wash p-3 text-body-sm text-text">
                  {complianceBlock}
                </div>
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
                  {rwaGate.checking
                    ? "Checking eligibility…"
                    : submitting
                      ? "Confirming…"
                      : "Confirm deposit"}
                </Button>
              )}
            </>
          )}
        </div>
      </Modal>
    </>
  );
}

/**
 * REAL deposit form for a registry pool: two-sided amount entry (either side may be
 * zero — the vault deploys what fits the ladder and refunds the remainder in the same
 * transaction), on-chain balances with Max, approve-then-deposit sequencing, and
 * pending/confirmed/failed states from the actual receipts.
 */
function LiveDepositBody({
  pool,
  live,
  riskClass,
  setRiskClass,
  geo,
  acked,
  setAcked,
  onClose,
}: {
  pool: PoolSummary;
  live: LivePool;
  riskClass: RiskClass;
  setRiskClass: (rc: RiskClass) => void;
  geo: GeoFenceResult;
  acked: boolean;
  setAcked: (b: boolean) => void;
  onClose: () => void;
}) {
  const { isConnected, address } = useAccount();
  const { openConnectModal } = useConnectModal();
  const dep = useVaultDeposit(live);
  const gate = useDepositGate(live.poolId);
  const rwaGate = useRwaComplianceGate();
  const [amtMeme, setAmtMeme] = useState("");
  const [amtQuote, setAmtQuote] = useState("");
  const [complianceBlock, setComplianceBlock] = useState<string | null>(null);

  // Registry sides ↔ the pool's true token0/token1 order (what deposit() expects).
  const memeIs0 = !live.quoteIsToken0;
  const memeBalance = memeIs0 ? dep.balance0 : dep.balance1;
  const quoteBalance = memeIs0 ? dep.balance1 : dep.balance0;
  const memeAllowance = memeIs0 ? dep.allowance0 : dep.allowance1;
  const quoteAllowance = memeIs0 ? dep.allowance1 : dep.allowance0;

  const memeWei = parseAmount(amtMeme, live.memecoinDecimals);
  const quoteWei = parseAmount(amtQuote, live.quoteDecimals);
  const anyAmount = (memeWei ?? 0n) > 0n || (quoteWei ?? 0n) > 0n;
  const overMeme =
    memeWei !== null && memeBalance !== undefined && memeWei > memeBalance;
  const overQuote =
    quoteWei !== null && quoteBalance !== undefined && quoteWei > quoteBalance;
  const needsApprove =
    (memeWei !== null && memeWei > 0n && (memeAllowance === undefined || memeAllowance < memeWei)) ||
    (quoteWei !== null && quoteWei > 0n && (quoteAllowance === undefined || quoteAllowance < quoteWei));

  // On-chain tranche id for the chosen risk profile (0 = Core/"Active", 1 = Anchor/"Steady").
  const tranche = RISK_CLASS_META[riskClass].tranche;
  const busy = txBusy(dep.phase);
  const paused = dep.depositsPaused === true;
  // Anti-manipulation price gate (see useDepositGate). Only a *known* closed state blocks;
  // admin-pause has its own banner below, so don't double up when both are true.
  const gateClosed = !paused && gate.open === false;
  const gateOpen = !paused && gate.open === true;

  const canConfirm =
    isConnected &&
    anyAmount &&
    memeWei !== null &&
    quoteWei !== null &&
    !overMeme &&
    !overQuote &&
    !paused &&
    !gateClosed &&
    !busy &&
    !geo.blocked &&
    (!geo.needsAck || acked) &&
    !rwaGate.checking;

  async function confirm() {
    if (memeWei === null || quoteWei === null) return;
    setComplianceBlock(null);
    // Tier-2 authoritative gate — RWA only. No registry pool is RWA-regime today (all
    // live on-chain pools are MEME), but this keeps the real deposit path correct for
    // whenever an RWA vault goes live: MEME pools skip this branch entirely, so no
    // added network call / logic for them.
    if (pool.regime === "RWA") {
      const verdict = await rwaGate.run(address ?? "");
      if (verdict.decision === "block") {
        setComplianceBlock(verdict.reason);
        return;
      }
    }
    void dep.submit({
      amount0: memeIs0 ? memeWei : quoteWei,
      amount1: memeIs0 ? quoteWei : memeWei,
      tranche,
      // TODO(slippage): pass a real minShares once the expected-shares quote is wired
      // (see useVaultTx.ts) — 0 means "accept whatever mints", fine for seed-scale size.
    });
  }

  const buttonLabel = () => {
    if (rwaGate.checking) return "Checking eligibility…";
    switch (dep.phase.step) {
      case "approve":
        return `Approve ${dep.phase.symbol} in wallet…`;
      case "approving":
        return `Approving ${dep.phase.symbol}…`;
      case "wallet":
        return "Confirm in wallet…";
      case "tx":
        return "Depositing…";
      case "error":
        return "Try again";
      default:
        if (gateClosed) return "Paused for a moment";
        if (overMeme) return `Not enough ${live.symbol}`;
        if (overQuote) return `Not enough ${live.quoteSymbol}`;
        if (paused) return "Deposits paused";
        return "Confirm deposit";
    }
  };

  if (dep.phase.step === "success") {
    return (
      <div className="space-y-3 py-2 text-center">
        <div className="mx-auto grid h-12 w-12 place-items-center rounded-full bg-pos-wash text-pos text-xl">
          ✓
        </div>
        <p className="text-body text-text">
          Deposited into {live.symbol}/{live.quoteSymbol} ·{" "}
          <span style={{ color: RISK_CLASS_META[riskClass].color }}>
            {RISK_CLASS_META[riskClass].label}
          </span>
          .
        </p>
        <p className="text-caption text-mute">
          You now hold vault shares. Fresh shares sit under a one-time 1-hour hold
          (no withdrawing or transferring them until it lapses); after that they&apos;re
          normal ERC-20s and your fees accrue automatically.
        </p>
        <a
          href={EXPLORER_TX(dep.phase.hash)}
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
      {/* Proactive deposit-gate status — surfaced before anything is filled in. A closed
          gate reopens on its own (useDepositGate re-probes every ~20s), which flips the
          button back on automatically; the post-submit error mapping is the backstop. */}
      {gateClosed ? (
        <div className="rounded-lg border border-warn-wash bg-warn-wash p-3 text-body-sm text-text">
          <div className="flex items-center gap-1.5">
            <span aria-hidden className="text-warn">⏳</span>
            <span className="font-semibold">Deposits are paused for a moment</span>
          </div>
          <p className="mt-1 text-caption text-dim">
            {live.symbol} is moving fast right now. This is a safety pause that protects the
            price you enter at — it reopens automatically, usually within a minute. Nothing to
            do; withdrawals are unaffected.
          </p>
        </div>
      ) : gateOpen ? (
        <div className="flex items-center gap-1.5 text-caption text-mute">
          <span aria-hidden className="h-1.5 w-1.5 rounded-full bg-pos" />
          Deposits open
        </div>
      ) : null}

      {/* two-sided amounts — either side may be zero */}
      <AmountField
        label={`${live.symbol} amount`}
        symbol={live.symbol}
        decimals={live.memecoinDecimals}
        value={amtMeme}
        onChange={setAmtMeme}
        balance={memeBalance}
        error={overMeme}
        disabled={busy}
      />
      <AmountField
        label={`${live.quoteSymbol} amount`}
        symbol={live.quoteSymbol}
        decimals={live.quoteDecimals}
        value={amtQuote}
        onChange={setAmtQuote}
        balance={quoteBalance}
        error={overQuote}
        disabled={busy}
      />
      <p className="text-caption text-mute">
        Deposit one token or both. The vault deploys what fits its bands and refunds
        any remainder in the same transaction.
      </p>

      {/* risk-profile selector (D-12 / D-16; user-facing terms per D-18) */}
      <RiskClassSelector
        pool={pool}
        value={riskClass}
        onChange={setRiskClass}
        variant="compact"
      />

      {/* Live on-chain facts — APRs render only when the indexer has real ones. */}
      {pool.chain?.statsPending ? (
        <div className="grid grid-cols-2 gap-2 rounded-lg border border-line bg-card p-3 text-center">
          <div>
            <div className="overline mb-1">Live fee</div>
            <div className="font-mono tnum text-body font-semibold text-text">
              {pool.chain.feeLive ? feePipsToPct(pool.currentFeePips) : "—"}
            </div>
          </div>
          <div>
            <div className="overline mb-1">Vault NAV</div>
            <div className="font-mono tnum text-body font-semibold text-text">
              {pool.chain.navQuote !== undefined
                ? `${tokenAmt(pool.chain.navQuote, 4)} ${pool.chain.quoteSymbol}`
                : "—"}
            </div>
          </div>
        </div>
      ) : (
        <p className="text-caption text-mute">
          Live fee {feePipsToPct(pool.currentFeePips)} · TVL {usdCompact(pool.tvlUsd)}
        </p>
      )}
      <p className="text-caption text-mute">
        A performance fee applies only to the fees you earn, never to your deposit.
      </p>

      {paused ? (
        <div className="rounded-lg border border-warn-wash bg-warn-wash p-3 text-body-sm text-text">
          Deposits for this pool are paused right now. Withdrawals are unaffected.
        </div>
      ) : null}

      {/* one-time post-deposit hold + share transfer-lock, surfaced before confirm */}
      <JitPenaltyNotice mode="deposit" />
      <p className="text-caption text-mute">
        The same 1-hour hold also transfer-locks the fresh shares themselves — they
        can&apos;t be moved to another wallet until it lapses.
      </p>

      {needsApprove && isConnected && !busy ? (
        <p className="text-caption text-dim">
          You&apos;ll be asked to approve{" "}
          {[
            memeWei !== null && memeWei > 0n && (memeAllowance === undefined || memeAllowance < memeWei)
              ? live.symbol
              : null,
            quoteWei !== null && quoteWei > 0n && (quoteAllowance === undefined || quoteAllowance < quoteWei)
              ? live.quoteSymbol
              : null,
          ]
            .filter(Boolean)
            .join(" and ")}{" "}
          first (exact amount), then confirm the deposit.
        </p>
      ) : null}

      {geo.needsAck ? (
        <label className="flex items-start gap-2 rounded-lg border border-warn-wash bg-warn-wash p-3 text-body-sm text-dim">
          <input
            type="checkbox"
            checked={acked}
            onChange={(e) => setAcked(e.target.checked)}
            className="mt-0.5 accent-[var(--accent2)]"
          />
          <span>
            {geo.reason} I understand the risk of providing to a stock-token pool and
            confirm eligibility.
          </span>
        </label>
      ) : null}

      {/* Tier-2 gate verdict (RWA only — see confirm()). Distinct from the geo banner
          above: this fires only at confirm time, from checks a country code alone
          can't make (VPN/Tor, wallet sanctions). */}
      {complianceBlock ? (
        <div className="rounded-lg border border-danger-line bg-danger-wash p-3 text-body-sm text-text">
          {complianceBlock}
        </div>
      ) : null}

      {dep.phase.step === "error" ? (
        <div className="rounded-lg border border-danger-line bg-danger-wash p-3 text-body-sm text-text">
          {dep.phase.message}
        </div>
      ) : null}

      {dep.phase.step === "tx" || dep.phase.step === "approving" ? (
        <p className="text-center text-caption text-mute">
          <a
            href={EXPLORER_TX(dep.phase.hash)}
            target="_blank"
            rel="noreferrer"
            className="font-medium text-accent2 hover:underline"
          >
            Track on Blockscout ↗
          </a>
        </p>
      ) : null}

      {!isConnected ? (
        <Button className="w-full" size="lg" onClick={() => openConnectModal?.()}>
          Connect wallet to deposit
        </Button>
      ) : (
        <Button
          className="w-full"
          size="lg"
          disabled={!canConfirm}
          onClick={confirm}
        >
          {buttonLabel()}
        </Button>
      )}
    </>
  );
}
