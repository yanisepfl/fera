"use client";

import { formatUnits } from "viem";
import { sanitizeAmountInput } from "@/lib/amount";
import { tokenAmt } from "@/lib/format";
import { cn } from "@/lib/cn";

/**
 * One token-amount input for the tx dialogs: label, live wallet balance with a Max
 * shortcut (Max writes the EXACT wei balance back as a string, so parseAmount
 * round-trips it losslessly), and the token symbol suffix.
 */
export function AmountField({
  label,
  symbol,
  decimals,
  value,
  onChange,
  balance,
  balanceLabel = "Balance",
  error,
  disabled,
}: {
  label: string;
  symbol: string;
  decimals: number;
  value: string;
  onChange: (v: string) => void;
  /** raw wei balance; undefined = not loaded (Max hidden). */
  balance?: bigint;
  balanceLabel?: string;
  /** true tints the field's border toward danger (e.g. amount exceeds balance). */
  error?: boolean;
  disabled?: boolean;
}) {
  return (
    <label className="block">
      <div className="flex items-center justify-between gap-2">
        <span className="overline">{label}</span>
        {balance !== undefined ? (
          <button
            type="button"
            disabled={disabled}
            onClick={() => onChange(formatUnits(balance, decimals))}
            className="text-caption text-mute transition-colors hover:text-dim disabled:opacity-50"
          >
            {balanceLabel}{" "}
            <span className="font-mono tnum">
              {tokenAmt(Number(formatUnits(balance, decimals)), 5)}
            </span>{" "}
            · <span className="font-medium text-accent2">Max</span>
          </button>
        ) : null}
      </div>
      <div
        className={cn(
          "mt-1 flex items-center gap-2 rounded-lg border bg-surface px-3 py-2.5 focus-within:border-accent-line",
          error ? "border-danger-line" : "border-line"
        )}
      >
        <input
          inputMode="decimal"
          placeholder="0.00"
          value={value}
          disabled={disabled}
          onChange={(e) => onChange(sanitizeAmountInput(e.target.value))}
          className="w-full bg-transparent font-mono tnum text-title outline-none placeholder:text-mute disabled:opacity-60"
        />
        <span className="shrink-0 text-body-sm text-dim">{symbol}</span>
      </div>
    </label>
  );
}
