/** Display formatters. All numbers in the UI go through these so units stay consistent. */

/** hundredths-of-a-bip (pips) → percent string. 3000 → "0.30%", 30000 → "3.00%". */
export function feePipsToPct(pips: number, dp = 2): string {
  return `${(pips / 10_000).toFixed(dp)}%`;
}

/** raw fraction of pips (for math), 3000 → 0.003 */
export function feePipsToFraction(pips: number): number {
  return pips / 1_000_000;
}

/** decimal APR fraction → percent string. 0.184 → "18.4%". */
export function apr(frac: number, dp = 1): string {
  return `${(frac * 100).toFixed(dp)}%`;
}

/** signed percent for deltas. 0.023 → "+2.3%". */
export function signedPct(frac: number, dp = 2): string {
  const v = frac * 100;
  return `${v >= 0 ? "+" : ""}${v.toFixed(dp)}%`;
}

const usdFmt = (max: number) =>
  new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: max,
  });

/** Compact USD with a magnitude suffix. 1_820_000 → "$1.82M". */
export function usdCompact(n: number): string {
  const abs = Math.abs(n);
  if (abs >= 1_000_000_000) return `$${(n / 1_000_000_000).toFixed(2)}B`;
  if (abs >= 1_000_000) return `$${(n / 1_000_000).toFixed(2)}M`;
  if (abs >= 1_000) return `$${(n / 1_000).toFixed(1)}K`;
  return usdFmt(abs < 1 ? 4 : 2).format(n);
}

/** Full-precision USD. */
export function usd(n: number, dp = 2): string {
  return usdFmt(dp).format(n);
}

/** Plain number with thousands separators and fixed dp. */
export function num(n: number, dp = 0): string {
  return new Intl.NumberFormat("en-US", {
    minimumFractionDigits: dp,
    maximumFractionDigits: dp,
  }).format(n);
}

/** Token amount, trims trailing zeros, caps precision. */
export function tokenAmt(n: number, dp = 4): string {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: dp }).format(n);
}

/**
 * Parse an 18-dec integer STRING (the §8 v0.2 wire format for FERA/esFERA amounts) into a
 * JS number of whole tokens. Precision-safe for display magnitudes; the authoritative
 * value for any tx stays the raw string (never round-trip a claim amount through this).
 */
export function weiToTokens(wei: string, decimals = 18): number {
  if (!wei) return 0;
  const neg = wei.startsWith("-");
  const s = (neg ? wei.slice(1) : wei).replace(/[^0-9]/g, "").padStart(decimals + 1, "0");
  const whole = s.slice(0, s.length - decimals);
  const frac = s.slice(s.length - decimals);
  const n = Number(`${whole}.${frac}`);
  return neg ? -n : n;
}

/** 18-dec esFERA/FERA string → display string (e.g. "812600000000000000000" → "812.6"). */
export function esFera(wei: string, dp = 1): string {
  return tokenAmt(weiToTokens(wei), dp);
}

/** e.g. 1.82 → "1.82x" */
export function multiple(n: number, dp = 2): string {
  return `${n.toFixed(dp)}x`;
}

/** 0x1234…abcd */
export function shortHex(hex: string, lead = 6, tail = 4): string {
  if (hex.length <= lead + tail) return hex;
  return `${hex.slice(0, lead)}…${hex.slice(-tail)}`;
}

/** Countdown parts from a target unix-seconds timestamp relative to `now` (ms). */
export function countdown(endsAtSec: number, nowMs = Date.now()) {
  let s = Math.max(0, Math.floor(endsAtSec - nowMs / 1000));
  const d = Math.floor(s / 86400);
  s -= d * 86400;
  const h = Math.floor(s / 3600);
  s -= h * 3600;
  const m = Math.floor(s / 60);
  s -= m * 60;
  return { d, h, m, s, done: endsAtSec <= nowMs / 1000 };
}

/** "2d 14h 03m" style. */
export function countdownLabel(endsAtSec: number, nowMs = Date.now()): string {
  const { d, h, m, s } = countdown(endsAtSec, nowMs);
  const pad = (n: number) => String(n).padStart(2, "0");
  if (d > 0) return `${d}d ${pad(h)}h ${pad(m)}m`;
  return `${pad(h)}h ${pad(m)}m ${pad(s)}s`;
}
