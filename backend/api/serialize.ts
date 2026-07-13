// Deterministic bigint → decimal-string serialization for API responses.
//
// The API NEVER emits a raw JS number for a monetary value (float loss). USD lives as E6
// micro-dollars; token amounts live as 18-dec wei. These helpers render them as fixed-point
// decimal strings the Frontend can parse losslessly.

const NEG = (s: string, neg: boolean) => (neg ? `-${s}` : s);

/** Render a fixed-point bigint with `decimals` fractional digits, trimmed to `show` places. */
export function fixed(value: bigint, decimals: number, show = decimals): string {
  const neg = value < 0n;
  let v = neg ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = v / base;
  const frac = (v % base).toString().padStart(decimals, "0");
  const shown = show <= 0 ? "" : `.${frac.slice(0, show).padEnd(show, "0")}`;
  return NEG(`${whole.toString()}${shown}`, neg);
}

/** USD micro-dollars (E6) → "1234.5600" (4 dp for display). */
export function usd(e6: bigint): string {
  return fixed(e6, 6, 4);
}

/** 18-dec token wei → decimal string (6 dp for display). */
export function token(wei: bigint, show = 6): string {
  return fixed(wei, 18, show);
}

/** boostX18 (1e18 = 1x) → multiplier string "1.50". */
export function boost(boostX18: bigint): string {
  return fixed(boostX18, 18, 2);
}

/** basis points bigint → DECIMAL FRACTION string per §8 conventions v0.2 (0.12 = 12%),
 *  e.g. 4500n -> "0.4500". (The old percent renderer violated the pinned conventions.) */
export function bpsFraction(bps: bigint): string {
  return fixed(bps, 4, 4);
}

/**
 * JSON.stringify replacer that turns any stray bigint into its decimal string. Belt-and-braces:
 * responses should already be string-ified via the helpers above, but this prevents a 500 if a
 * bigint slips through (JSON.stringify throws on bigint otherwise).
 */
export function bigintReplacer(_key: string, value: unknown): unknown {
  return typeof value === "bigint" ? value.toString() : value;
}
