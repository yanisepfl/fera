/**
 * Terms-of-Service acceptance: the deterministic message the wallet signs, plus helpers.
 *
 * The signed message is the strongest record of acceptance we can capture client-side:
 * it commits to the ToS VERSION, a SHA-256 HASH of the exact terms text the user was
 * shown (computed from lib/legal/content.ts so it can never silently drift from the
 * rendered/PDF docs), the connecting ADDRESS, a NONCE, and an ISO TIMESTAMP. The backend
 * re-verifies the signature recovers `address` and that the message embeds the version +
 * address before storing it (see backend/api/tos.ts).
 */
import { LEGAL_VERSION, canonicalLegalText } from "@/lib/legal/content";

export const TOS_VERSION = LEGAL_VERSION;

/** Absolute URLs of the on-site legal routes, embedded in the signed message. */
export function legalDocUrls(origin?: string): string {
  const base = origin ?? (typeof window !== "undefined" ? window.location.origin : "https://fera.fi");
  return `${base}/legal/terms, ${base}/legal/privacy, ${base}/legal/risk`;
}

/** Random, non-guessable nonce for the acceptance (replay-distinct records). */
export function makeNonce(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return crypto.randomUUID();
  return Math.random().toString(36).slice(2) + Date.now().toString(36);
}

/**
 * SHA-256 of the canonical legal text, hex, prefixed "sha256:". Uses Web Crypto
 * (available in secure contexts incl. localhost + https). Falls back to a URL-only
 * marker if SubtleCrypto is unavailable (e.g. insecure non-localhost http), so signing
 * still works — the message then commits to the version + documents URL instead.
 */
export async function computeTermsHash(): Promise<string> {
  try {
    const subtle = typeof crypto !== "undefined" ? crypto.subtle : undefined;
    if (!subtle) return "url-only";
    const bytes = new TextEncoder().encode(canonicalLegalText());
    const digest = await subtle.digest("SHA-256", bytes);
    const hex = Array.from(new Uint8Array(digest))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    return `sha256:${hex}`;
  } catch {
    return "url-only";
  }
}

export interface TosMessageParts {
  address: string;
  nonce: string;
  issuedAt: string; // ISO-8601
  termsHash: string;
  origin?: string;
}

/**
 * The exact multi-line message the wallet signs. Deterministic given its parts, so the
 * signature is reproducible and the backend's structural checks (must contain the
 * `Version:` and `Wallet:` lines) are stable. Wording makes clear no gas/tx is involved.
 */
export function buildTosMessage({ address, nonce, issuedAt, termsHash, origin }: TosMessageParts): string {
  return [
    "FERA — Terms of Service Acceptance",
    "",
    "By signing this message I confirm that I have read, understood, and agree to the",
    "FERA Terms of Service, Privacy Policy, and Risk Disclosure, including that FERA is",
    "experimental, unaudited, non-custodial software and that I may lose all deposited",
    "assets. This is not financial advice.",
    "",
    `Version: ${TOS_VERSION}`,
    `Documents: ${legalDocUrls(origin)}`,
    `Terms Hash: ${termsHash}`,
    `Wallet: ${address}`,
    `Nonce: ${nonce}`,
    `Issued At: ${issuedAt}`,
    "",
    "This request will not trigger a blockchain transaction or cost any gas.",
  ].join("\n");
}

export interface TosAcceptancePayload {
  address: string;
  version: string;
  message: string;
  signature: string;
  timestamp: string;
  termsHash: string;
}
