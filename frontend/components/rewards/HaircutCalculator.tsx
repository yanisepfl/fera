"use client";

import { useState } from "react";
import { Card, CardHeader } from "@/components/ui/Card";
import { HaircutBreakdown } from "./HaircutBreakdown";
import { InfoTip } from "@/components/ui/InfoTip";

/**
 * Standalone instant-exit HAIRCUT CALCULATOR. Type an esFERA amount and see exactly
 * what you'd lose before ever confirming. This is the "forfeiture impossible to miss"
 * surface required for the vesting dashboard.
 */
export function HaircutCalculator({ presetBalance = 2652.6 }: { presetBalance?: number }) {
  const [raw, setRaw] = useState("1000");
  const amount = Number(raw) || 0;

  return (
    <Card>
      <CardHeader
        eyebrow="Instant-exit calculator"
        title="What would exiting cost you?"
        action={
          <InfoTip text="Instant exit converts esFERA to FERA now at a 50% haircut. The forfeited half is split 1/3 burn, 1/3 stakers, 1/3 revenue (INV-9)." />
        }
      />
      <div className="px-5 pb-5 space-y-4">
        <label className="block">
          <div className="mb-1 flex items-center justify-between">
            <span className="overline">esFERA to instant-exit</span>
            <button
              className="text-caption text-accent hover:text-accent-strong"
              onClick={() => setRaw(String(presetBalance))}
            >
              Max {presetBalance.toLocaleString()}
            </button>
          </div>
          <div className="flex items-center gap-2 rounded-lg border border-line bg-surface px-3 py-2.5 focus-within:border-accent-line">
            <input
              inputMode="decimal"
              value={raw}
              onChange={(e) => setRaw(e.target.value.replace(/[^0-9.]/g, ""))}
              className="w-full bg-transparent font-mono tnum text-title outline-none placeholder:text-mute"
              placeholder="0.00"
            />
            <span className="text-body-sm text-dim">esFERA</span>
          </div>
          <input
            type="range"
            min={0}
            max={presetBalance}
            step={1}
            value={Math.min(amount, presetBalance)}
            onChange={(e) => setRaw(e.target.value)}
            className="mt-3 w-full accent-[var(--danger)]"
            aria-label="Amount to instant-exit"
          />
        </label>

        <HaircutBreakdown amount={amount} />
      </div>
    </Card>
  );
}
