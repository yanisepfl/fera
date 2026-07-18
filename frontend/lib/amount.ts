import { parseUnits } from "viem";

/**
 * Decimal token-amount input helpers for the tx dialogs. Inputs are plain decimal
 * strings; the AUTHORITATIVE value is always the parsed bigint (wei) — never a float.
 */

/** Keep only digits and the FIRST dot while typing ("1.2.3" → "1.23"). */
export function sanitizeAmountInput(s: string): string {
  const cleaned = s.replace(/[^0-9.]/g, "");
  const i = cleaned.indexOf(".");
  if (i === -1) return cleaned;
  return cleaned.slice(0, i + 1) + cleaned.slice(i + 1).replace(/\./g, "");
}

/**
 * Parse a sanitized decimal string to wei. "" → 0n (empty field, not an error);
 * malformed → null. Fractional digits beyond `decimals` are truncated (rounding
 * DOWN — never submit more than the user typed).
 */
export function parseAmount(s: string, decimals: number): bigint | null {
  if (!s || s === ".") return 0n;
  if (!/^\d*\.?\d*$/.test(s)) return null;
  const [whole, frac = ""] = s.split(".");
  try {
    return parseUnits(`${whole || "0"}.${frac.slice(0, decimals) || "0"}`, decimals);
  } catch {
    return null;
  }
}
