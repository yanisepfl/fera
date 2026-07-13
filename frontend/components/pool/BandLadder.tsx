"use client";

import type { PoolDetail, LadderBand } from "@/lib/types";
import { Card, CardHeader } from "@/components/ui/Card";
import { InfoTip } from "@/components/ui/InfoTip";
import { multiple } from "@/lib/format";
import { cn } from "@/lib/cn";

const ROLE_META: Record<
  LadderBand["role"],
  { label: string; color: string; wash: string }
> = {
  core: { label: "Core", color: "var(--accent)", wash: "rgba(231,184,75,0.22)" },
  mid: { label: "Mid", color: "var(--regime-rwa)", wash: "rgba(90,169,230,0.20)" },
  tail: { label: "Tail", color: "var(--text-mute)", wash: "rgba(110,110,121,0.22)" },
  fee: { label: "Fee drip", color: "var(--pos)", wash: "rgba(70,192,138,0.20)" },
};

/** Relative band edges from a geometric factor k (band = [P/k, P·k]). */
function relPct(k?: number): { lo: number; hi: number } {
  if (!k) return { lo: -100, hi: 100 }; // tail / full range
  return { lo: (1 / k - 1) * 100, hi: (k - 1) * 100 };
}

/**
 * MEME band ladder (VAULT_ARCHITECTURE §2.1). Renders the discrete principal bands
 * (Core / Mid / Tail) plus fee-drip bands on a shared log-price axis centered on spot, so a
 * depositor can SEE that liquidity is shaped — concentrated at price, fat tails for crashes —
 * not a single full-range blob and not something that churns principal.
 */
export function BandLadder({ pool }: { pool: PoolDetail }) {
  const ladder = pool.ladder ?? [];
  if (!ladder.length) return null;

  // Log axis over [P/2.6, P·2.6]; the tail band clamps to the full width.
  const domain = 2.6;
  const pos = (rel: number) => {
    // rel is % from spot → multiplier
    const mult = 1 + rel / 100;
    const clamped = Math.max(1 / domain, Math.min(domain, mult));
    return ((Math.log(clamped) + Math.log(domain)) / (2 * Math.log(domain))) * 100;
  };
  const spotPos = pos(0);

  // Order bands widest→narrowest so narrow bands render on top.
  const rows = [...ladder].sort((a, b) => (b.k ?? 999) - (a.k ?? 999));

  return (
    <Card>
      <CardHeader
        eyebrow="MEME strategy · shaped liquidity"
        title="The band ladder"
        action={
          <InfoTip text="Principal is minted once as a ladder of discrete bands — concentrated near price (wins routing), fat tails for crash coverage. Weights 30/40/30 (Core/Mid/Tail). Fee income drips into new bands at spot to follow price; principal bands are never closed or swapped (INV-5″)." />
        }
      />
      <div className="px-5 pb-5 space-y-4">
        {/* band diagram */}
        <div className="relative rounded-lg border border-line bg-well px-3 py-4">
          <div className="relative h-[104px]">
            {/* spot marker */}
            <div
              className="absolute inset-y-0 z-20 w-px bg-text/70"
              style={{ left: `${spotPos}%` }}
            >
              <span className="absolute -top-3 left-1/2 -translate-x-1/2 whitespace-nowrap text-[10px] font-semibold text-text">
                spot
              </span>
            </div>
            {rows.map((b, i) => {
              const { lo, hi } = relPct(b.k);
              const left = pos(lo);
              const right = pos(hi);
              const rm = ROLE_META[b.role];
              const top = 8 + i * 22;
              return (
                <div
                  key={`${b.role}-${i}`}
                  className={cn(
                    "absolute h-4 rounded-[3px] border",
                    b.isPrincipal ? "" : "border-dashed"
                  )}
                  style={{
                    left: `${left}%`,
                    width: `${Math.max(2, right - left)}%`,
                    top,
                    background: rm.wash,
                    borderColor: rm.color,
                  }}
                  title={`${rm.label} — ${b.isPrincipal ? "principal" : "fee-drip"}`}
                >
                  <span
                    className="absolute left-1.5 top-1/2 -translate-y-1/2 whitespace-nowrap text-[10px] font-semibold"
                    style={{ color: rm.color }}
                  >
                    {rm.label}
                  </span>
                </div>
              );
            })}
          </div>
          <div className="mt-1 flex justify-between text-caption text-mute font-mono tnum">
            <span>−60%</span>
            <span>price</span>
            <span>+160%</span>
          </div>
        </div>

        {/* band table */}
        <div className="space-y-1.5">
          {ladder.map((b, i) => {
            const { lo, hi } = relPct(b.k);
            const rm = ROLE_META[b.role];
            return (
              <div
                key={`row-${i}`}
                className="grid grid-cols-[auto_1fr_auto_auto] items-center gap-3 text-caption"
              >
                <span className="flex items-center gap-1.5">
                  <span
                    className={cn("h-2 w-2 rounded-sm", b.isPrincipal ? "" : "opacity-60")}
                    style={{ background: rm.color }}
                  />
                  <span className="w-16 font-semibold text-dim">{rm.label}</span>
                </span>
                <span className="font-mono tnum text-mute">
                  {b.k ? `${lo.toFixed(0)}% / +${hi.toFixed(0)}%` : "full range"}
                </span>
                <span className="font-mono tnum text-mute">
                  {b.weightBps ? `${(b.weightBps / 100).toFixed(0)}%` : "fee income"}
                </span>
                <span className="w-14 text-right font-mono tnum text-text">
                  {b.depthMult ? `${multiple(b.depthMult, 1)}` : "—"}
                </span>
              </div>
            );
          })}
          <div className="grid grid-cols-[auto_1fr_auto_auto] gap-3 border-t border-line pt-1.5 text-micro uppercase tracking-wide text-mute">
            <span className="w-[74px]">band</span>
            <span>range vs spot</span>
            <span>weight</span>
            <span className="w-14 text-right">depth</span>
          </div>
        </div>

        <p className="text-caption text-mute">
          Weighted at-spot depth is ≈4.1× a single full-range position per dollar — before a
          single extra deposit. <span className="text-pos">Solid</span> bands are principal
          (never churned); <span className="text-pos">dashed</span> are fee-drip bands the
          vault mints at spot from collected fees.
        </p>
      </div>
    </Card>
  );
}
