/**
 * Tor exit-node backstop — SERVER-ONLY.
 *
 * Do not import this from a client component; only lib/compliance/decision.ts calls it.
 *
 * Free bulk list from the Tor Project (https://check.torproject.org/torbulkexitlist),
 * fetched and cached in-memory, revalidated every few hours. This is a supplementary
 * signal alongside ipapi.is's own `is_tor` flag — two independent sources reduce the
 * chance a single stale list misses a live exit node (or over-flags one that rotated
 * out).
 *
 * FAIL-OPEN on refresh failure: if the list can't be fetched, fall back to the last-good
 * cached list as long as it isn't too stale (< 24h); if there is no usable cache at all,
 * this check contributes no signal ("error") rather than blocking — same reasoning as
 * ipapi.ts's fail-open choice: an infra hiccup fetching a PUBLIC list isn't evidence of
 * anything about the requester, and the primary country blocklist still applies
 * regardless (see decision.ts).
 */

if (typeof window !== "undefined") {
  throw new Error(
    "lib/compliance/torList.ts is server-only and must not be imported into a client bundle"
  );
}

const TOR_LIST_URL = "https://check.torproject.org/torbulkexitlist";
const REVALIDATE_MS = 4 * 60 * 60 * 1000; // 4h — "revalidate every few hours" per spec
const STALE_CEILING_MS = 24 * 60 * 60 * 1000; // never trust a cache older than this

let cache: { set: Set<string>; fetchedAt: number } | null = null;
let inFlight: Promise<Set<string>> | null = null;

async function fetchList(): Promise<Set<string>> {
  const res = await fetch(TOR_LIST_URL, { headers: { accept: "text/plain" } });
  if (!res.ok) throw new Error(`torbulkexitlist responded ${res.status}`);
  const text = await res.text();
  const ips = text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
  return new Set(ips);
}

async function getList(): Promise<Set<string> | null> {
  if (cache && Date.now() - cache.fetchedAt < REVALIDATE_MS) return cache.set;

  if (!inFlight) {
    inFlight = fetchList()
      .then((set) => {
        cache = { set, fetchedAt: Date.now() };
        return set;
      })
      .finally(() => {
        inFlight = null;
      });
  }

  try {
    return await inFlight;
  } catch {
    // Refresh failed — serve a stale-but-not-ancient cache if one exists.
    if (cache && Date.now() - cache.fetchedAt < STALE_CEILING_MS) return cache.set;
    return null; // no usable signal at all — see FAIL-OPEN note above.
  }
}

export type TorCheckStatus = "ok" | "error";

export interface TorCheckResult {
  status: TorCheckStatus;
  isExitNode: boolean;
}

export async function checkTorExitNode(ip: string): Promise<TorCheckResult> {
  const list = await getList();
  if (list === null) {
    return { status: "error", isExitNode: false };
  }
  return { status: "ok", isExitNode: list.has(ip) };
}
