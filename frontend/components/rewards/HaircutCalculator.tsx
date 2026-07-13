"use client";

import { useState } from "react";
import { Card, CardHeader } from "@/components/ui/Card";
import { HaircutBreakdown } from "./HaircutBreakdown";
import { InfoTip } from "@/components/ui/InfoTip";

/**
 * Instant-exit calculator. Type an esFERA amount and see the trade in one glance:
 * exit now for half, or wait the vest for all of it. Dead simple, no fine print.
 */
export function HaircutCalculator({ presetBalance = 2652.6 }: { presetBalance?: number }) {
  const [raw, setRaw] = useState("1000");
  const amount = Number(raw) || 0;

  return (
    <Card className="card-glow">
      <CardHeader
        eyebrow={<span className="text-accent">Instant exit</span>}
        title="Exit now, or wait to vest?"
        action={
          <InfoTip text="Instant exit turns esFERA into FERA right now, at half its value. Wait the vest and you keep all of it." />
        }
      />
      <div className="px-5 pb-5 space-y-4">
        <label className="block">
          <div className="mb-1 flex items-center justify-between">
            <span className="overline">esFERA to exit</span>
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
            aria-label="Amount to exit"
          />
        </label>

        <HaircutBreakdown amount={amount} />
      </div>
    </Card>
  );
}
