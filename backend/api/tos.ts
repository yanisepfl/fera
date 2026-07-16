// Terms-of-Service acceptance verification + handlers.
//
// The acceptance record is a wallet signature (personal_sign) over a deterministic
// message that embeds the ToS version, a terms hash/URL, the connecting address, a
// nonce and an ISO timestamp. The server NEVER trusts the `address` field on its own:
// it recovers the signer from (message, signature) with viem and requires it to equal
// the claimed address before recording. It also requires the signed message to embed
// the claimed version + address, so a signature can't be replayed to assert acceptance
// of a different version or on behalf of a different wallet.
//
// EOA note: personal_sign yields a 65-byte EOA signature, so we recover with viem's
// `recoverMessageAddress` and compare checksums — offline, no RPC/public-client needed
// (viem's `verifyMessage` action would require a client for 1271/6492 smart accounts;
// FERA's gate targets EOAs, so recover-and-compare is the correct, dependency-free check).

import { recoverMessageAddress, getAddress, isAddress } from "viem";
import type { TosStore, TosAcceptance } from "./tosStore";

export interface HandlerResult {
  status: number;
  body: unknown;
}

export interface AcceptMeta {
  ip?: string;
  userAgent?: string;
}

const VERSION_RE = /^[A-Za-z0-9._:-]{1,64}$/;
const SIG_RE = /^0x[0-9a-fA-F]{130,}$/; // >= 65 bytes
const MAX_MESSAGE_LEN = 4000;

/** Version param validation shared by accept + status (also an SSRF/eng-noise guard). */
export function validVersion(v: unknown): v is string {
  return typeof v === "string" && VERSION_RE.test(v);
}

export function validAddress(a: unknown): a is string {
  return typeof a === "string" && isAddress(a);
}

const bad = (error: string): HandlerResult => ({ status: 400, body: { error } });

/**
 * POST /tos/accept — verify the signature recovers `address`, sanity-check the signed
 * message, then durably record the acceptance. Idempotent: re-accepting the same
 * (address, version) is fine and simply appends another dated record.
 */
export async function handleAccept(
  store: TosStore,
  input: unknown,
  meta: AcceptMeta = {},
): Promise<HandlerResult> {
  if (typeof input !== "object" || input === null) return bad("body must be a JSON object");
  const { address, version, message, signature, timestamp, termsHash } = input as Record<
    string,
    unknown
  >;

  if (!validAddress(address)) return bad("address must be a 0x EOA address");
  if (!validVersion(version)) return bad("version must match [A-Za-z0-9._:-]{1,64}");
  if (typeof message !== "string" || message.length === 0 || message.length > MAX_MESSAGE_LEN)
    return bad("message must be a non-empty string <= 4000 chars");
  if (typeof signature !== "string" || !SIG_RE.test(signature))
    return bad("signature must be a 0x personal_sign hex");
  if (timestamp !== undefined && typeof timestamp !== "string")
    return bad("timestamp must be an ISO string");
  if (termsHash !== undefined && typeof termsHash !== "string")
    return bad("termsHash must be a string");

  // The signed message MUST embed what it claims, so a valid signature can't be
  // replayed to assert a different version or a different wallet.
  if (!message.includes(`Version: ${version}`))
    return bad("signed message does not embed the claimed version");
  if (!message.toLowerCase().includes((address as string).toLowerCase()))
    return bad("signed message does not embed the claimed address");

  // Cryptographic check: recover the signer and require it to equal the claim.
  let recovered: string;
  try {
    recovered = await recoverMessageAddress({
      message: message as string,
      signature: signature as `0x${string}`,
    });
  } catch {
    return { status: 401, body: { error: "signature did not recover a valid address" } };
  }
  if (getAddress(recovered) !== getAddress(address as string))
    return { status: 401, body: { error: "signature does not match the claimed address" } };

  const record: TosAcceptance = {
    address: (address as string).toLowerCase(),
    version: version as string,
    message: message as string,
    signature: signature as string,
    timestamp: (typeof timestamp === "string" && timestamp) || new Date().toISOString(),
    recordedAt: new Date().toISOString(),
    termsHash: typeof termsHash === "string" ? termsHash : undefined,
    ip: meta.ip,
    userAgent: meta.userAgent,
  };
  await store.recordAcceptance(record);

  return {
    status: 201,
    body: { ok: true, address: record.address, version: record.version, recordedAt: record.recordedAt },
  };
}

/** GET /tos/status?address=&version= → { accepted: boolean }. */
export async function handleStatus(
  store: TosStore,
  address: unknown,
  version: unknown,
): Promise<HandlerResult> {
  if (!validAddress(address)) return bad("address must be a 0x EOA address");
  if (!validVersion(version)) return bad("version must match [A-Za-z0-9._:-]{1,64}");
  const accepted = await store.hasAccepted(address as string, version as string);
  return { status: 200, body: { accepted, address: (address as string).toLowerCase(), version } };
}
