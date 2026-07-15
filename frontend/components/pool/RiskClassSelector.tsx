"use client";

import type { PoolSummary, RiskClass } from "@/lib/types";
import {
  RISK_CLASS_META,
  RISK_CLASS_ORDER,
  RISK_CLASS_GROUP_LABEL,
  availableRiskClasses,
} from "@/lib/riskClass";
import { Card, CardHeader } from "@/components/ui/Card";
import { InfoTip } from "@/components/ui/InfoTip";
import { apr } from "@/lib/format";
import { cn } from "@/lib/cn";

/**
 * Risk-profile selector (D-12 risk classes; user-facing terms per D-18, NEVER "tranche").
 * RWA pools offer Active + Steady; MEME offers Active only (D-16). Shows each class's
 * fee-capture ↔ impermanent-loss trade-off in plain language + its own APR when the pool
 * carries per-class `tranches[]` data.
 *
 * `variant="cards"` is the standalone Pool-page picker (full trade-off copy).
 * `variant="compact"` is the segmented control inside the Deposit dialog.
 */
export function RiskClassSelector({
  pool,
  value,
  onChange,
  variant = "cards",
}: {
  pool: PoolSummary;
  value: RiskClass;
  onChange: (rc: RiskClass) => void;
  variant?: "cards" | "compact";
}) {
  const classes =
    pool.tranches && pool.tranches.length
      ? (pool.tranches.map((t) => t.riskClass) as RiskClass[])
      : availableRiskClasses(pool.regime);
  const ordered = RISK_CLASS_ORDER.filter((rc) => classes.includes(rc));
  const only = ordered.length === 1;
  const trancheOf = (rc: RiskClass) =>
    pool.tranches?.find((t) => t.riskClass === rc);

  if (variant === "compact") {
    return (
      <div>
        <div className="mb-1 flex items-center gap-1">
          <span className="overline">{RISK_CLASS_GROUP_LABEL}</span>
          <InfoTip text="Two managed risk levels over the same pool. Active concentrates near the price for more fees and bigger swings; Steady spreads wide for less of both." />
        </div>
        {only ? (
          <SingleClassNote rc={ordered[0]} regime={pool.regime} />
        ) : (
          <div className="grid grid-cols-2 gap-2">
            {ordered.map((rc) => {
              const m = RISK_CLASS_META[rc];
              const t = trancheOf(rc);
              const active = rc === value;
              return (
                <button
                  key={rc}
                  type="button"
                  onClick={() => onChange(rc)}
                  aria-pressed={active}
                  className={cn(
                    "rounded-lg border p-3 text-left transition-colors",
                    active
                      ? "border-accent-line bg-accent-wash"
                      : "border-line bg-surface hover:border-line-strong"
                  )}
                >
                  <div className="flex items-center justify-between">
                    <span
                      className="text-body-sm font-semibold"
                      style={{ color: active ? "var(--text)" : m.color }}
                    >
                      {m.label}
                    </span>
                    {active ? (
                      <span className="text-accent text-caption">●</span>
                    ) : null}
                  </div>
                  <div className="mt-0.5 text-caption text-mute">{m.tagline}</div>
                  {t ? (
                    <div className="mt-2 font-mono tnum text-caption text-dim">
                      {apr(t.feeApr + t.emissionsApr)} total APR
                    </div>
                  ) : null}
                </button>
              );
            })}
          </div>
        )}
        <p className="mt-2 text-caption text-mute">
          {RISK_CLASS_META[value].feeCapture}{" "}
          <span className="text-dim">{RISK_CLASS_META[value].il}</span>
        </p>
      </div>
    );
  }

  return (
    <Card>
      <CardHeader
        eyebrow={RISK_CLASS_GROUP_LABEL}
        title="Pick your risk level"
        action={
          <InfoTip text="Each level is managed separately, with its own fees. Pick one when you deposit - you can hold both." />
        }
      />
      <div className="px-5 pb-5 space-y-3">
        <div className={cn("grid gap-3", only ? "" : "sm:grid-cols-2")}>
          {ordered.map((rc) => {
            const m = RISK_CLASS_META[rc];
            const t = trancheOf(rc);
            const active = rc === value;
            return (
              <button
                key={rc}
                type="button"
                onClick={() => onChange(rc)}
                aria-pressed={active}
                className={cn(
                  "rounded-lg border p-4 text-left transition-colors",
                  active
                    ? "border-accent-line bg-accent-wash"
                    : "border-line bg-well hover:border-line-strong"
                )}
              >
                <div className="flex items-center justify-between">
                  <span className="text-heading font-semibold" style={{ color: m.color }}>
                    {m.label}
                  </span>
                  {t ? (
                    <span className="text-right">
                      <span className="block font-mono tnum text-body font-semibold text-text">
                        {apr(t.feeApr + t.emissionsApr)}
                      </span>
                      <span className="text-micro uppercase tracking-wide text-mute">
                        total APR
                      </span>
                    </span>
                  ) : null}
                </div>
                <p className="mt-1 text-body-sm text-dim">{m.tagline}</p>

                <dl className="mt-3 space-y-2 text-caption">
                  <TradeoffRow label="Fees earned" color="var(--pos)" text={m.feeCapture} />
                  <TradeoffRow label="Position swings" color="var(--neg)" text={m.il} />
                </dl>

                <p className="mt-3 border-t border-line pt-2 text-caption text-mute">
                  {m.persona}
                  {t ? (
                    <>
                      {" · "}
                      <span className="font-mono">{t.shareSymbol}</span>
                    </>
                  ) : null}
                </p>
              </button>
            );
          })}
        </div>

        {only ? (
          <SingleClassNote rc={ordered[0]} regime={pool.regime} full />
        ) : null}
      </div>
    </Card>
  );
}

function TradeoffRow({ label, color, text }: { label: string; color: string; text: string }) {
  return (
    <div className="flex gap-2">
      <span
        className="mt-1 h-1.5 w-1.5 shrink-0 rounded-full"
        style={{ background: color }}
      />
      <span>
        <span className="font-semibold text-dim">{label}. </span>
        <span className="text-mute">{text}</span>
      </span>
    </div>
  );
}

/** MEME pools ship a single (Active) profile, D-16. Explain why, honestly. */
function SingleClassNote({
  rc,
  regime,
  full,
}: {
  rc: RiskClass;
  regime: PoolSummary["regime"];
  full?: boolean;
}) {
  const m = RISK_CLASS_META[rc];
  return (
    <div className="rounded-lg border border-line bg-well p-3 text-caption text-mute">
      {regime === "MEME" ? (
        <>
          This meme-coin pool offers the{" "}
          <span className="font-semibold" style={{ color: m.color }}>
            {m.label}
          </span>{" "}
          level only. On a meme coin, a wide Steady range barely differs from just holding
          the tokens. Steady arrives with tokenized stocks, where it fits.
        </>
      ) : (
        <>Only the {m.label} level is available for this pool.</>
      )}
      {full ? <div className="mt-1">{m.persona}</div> : null}
    </div>
  );
}
