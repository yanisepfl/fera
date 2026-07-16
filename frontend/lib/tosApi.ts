/**
 * Terms-of-Service acceptance client.
 *
 * Source of truth is the backend ledger (POST /tos/accept, GET /tos/status) when
 * NEXT_PUBLIC_API_URL is configured. In pure fixture/demo mode (no API URL) there is no
 * server to record to, so acceptance is captured locally: the signature is still produced
 * and the acceptance is remembered in localStorage so the app is usable without a backend.
 * The local cache is only ever written AFTER a confirmed acceptance (server 2xx, or the
 * local-only path), so a failed server write can never silently bypass the gate on reload.
 */
import type { TosAcceptancePayload } from "@/lib/tos";

const API_URL = process.env.NEXT_PUBLIC_API_URL?.replace(/\/$/, "") ?? "";
const HAS_SERVER = !!API_URL;

const localKey = (address: string, version: string) =>
  `fera.tos.${version}.${address.toLowerCase()}`;

function cacheLocally(address: string, version: string) {
  try {
    localStorage.setItem(localKey(address, version), "1");
  } catch {
    /* storage disabled — non-fatal */
  }
}

function cachedLocally(address: string, version: string): boolean {
  try {
    return localStorage.getItem(localKey(address, version)) === "1";
  } catch {
    return false;
  }
}

export interface TosStatus {
  accepted: boolean;
  /** Whether the answer came from the server ledger or a local record. */
  source: "server" | "local";
}

/** True if the interface has a server ledger configured (else local-only mode). */
export const tosHasServer = HAS_SERVER;

export async function getTosStatus(address: string, version: string): Promise<TosStatus> {
  // Local cache is only set on a CONFIRMED acceptance, so trusting it here is safe and
  // avoids a re-prompt flash on every reload.
  if (cachedLocally(address, version)) return { accepted: true, source: "local" };
  if (!HAS_SERVER) return { accepted: false, source: "local" };
  try {
    const res = await fetch(
      `${API_URL}/tos/status?address=${encodeURIComponent(address)}&version=${encodeURIComponent(version)}`,
      { headers: { accept: "application/json" }, cache: "no-store" },
    );
    if (!res.ok) return { accepted: false, source: "server" };
    const body = (await res.json()) as { accepted?: boolean };
    if (body.accepted) cacheLocally(address, version);
    return { accepted: !!body.accepted, source: "server" };
  } catch {
    // Backend unreachable: treat as not-accepted so the gate stays up (fail closed).
    return { accepted: false, source: "server" };
  }
}

export async function postTosAcceptance(
  payload: TosAcceptancePayload,
): Promise<{ recorded: "server" | "local" }> {
  if (!HAS_SERVER) {
    cacheLocally(payload.address, payload.version);
    return { recorded: "local" };
  }
  const res = await fetch(`${API_URL}/tos/accept`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    let detail = "";
    try {
      detail = JSON.stringify(await res.json());
    } catch {
      /* ignore */
    }
    throw new Error(`Recording acceptance failed (${res.status}). ${detail}`);
  }
  cacheLocally(payload.address, payload.version); // only after server confirmed
  return { recorded: "server" };
}
