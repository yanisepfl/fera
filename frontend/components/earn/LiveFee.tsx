"use client";

import { useLiveFee } from "@/lib/hooks/useLiveFee";
import { feePipsToPct } from "@/lib/format";
import type { Regime } from "@/lib/types";
import { cn } from "@/lib/cn";

/**
 * The LIVE dynamic fee, rendered as an updating mono number. Flashes accent on each
 * tick and shows the direction arrow. `size="hero"` is the Earn-home centerpiece.
 *
 * `live={false}` (pre-launch live mode, `vaultLive:false`): the vault fee does not
 * exist yet, so we render a static "—" — no number, no simulated movement.
 */
export function LiveFee({
  seedPips,
  regime,
  size = "row",
  live = true,
  className,
}: {
  seedPips: number;
  regime: Regime;
  size?: "hero" | "row";
  live?: boolean;
  className?: string;
}) {
  const { pips, direction, tick } = useLiveFee(seedPips, regime, 1600, live);

  if (!live) {
    return (
      <span
        className={cn("inline-flex items-baseline gap-1.5", className)}
        title="The dynamic fee goes live when the vault launches"
      >
        <span className="font-mono tnum text-body font-semibold text-mute">—</span>
        <span className="text-caption text-mute">at launch</span>
      </span>
    );
  }
  const arrow = direction > 0 ? "▲" : direction < 0 ? "▼" : "";
  const arrowColor =
    direction > 0 ? "var(--pos)" : direction < 0 ? "var(--neg)" : "var(--text-mute)";

  if (size === "hero") {
    return (
      <div className={cn("flex items-end gap-3", className)}>
        <span
          key={tick}
          className="font-mono tnum text-hero font-semibold leading-none animate-tick-flash text-text"
        >
          {feePipsToPct(pips)}
        </span>
        {arrow ? (
          <span
            className="font-mono text-body-sm mb-2"
            style={{ color: arrowColor }}
          >
            {arrow}
          </span>
        ) : null}
      </div>
    );
  }

  return (
    <span className={cn("inline-flex items-center gap-1", className)}>
      <span
        key={tick}
        className="font-mono tnum text-body font-semibold text-text animate-tick-flash"
      >
        {feePipsToPct(pips)}
      </span>
      {arrow ? (
        <span className="text-[9px]" style={{ color: arrowColor }}>
          {arrow}
        </span>
      ) : null}
    </span>
  );
}
