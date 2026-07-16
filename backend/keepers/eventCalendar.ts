// KEEPER 5/5 — RWA event-calendar guard (MASTER_SPEC v0.6 §10 new row, D-M11 / PT-7).
//
// TRIGGER: scheduled earnings / known event windows (an exogenous calendar: earnings before
// the next open for the pool's underlying).
// ACTION: FeraVault.setEventWindow(poolId, active) — flips a per-pool boolean for the
// affected session ONLY.
//
// ON-CHAIN VERIFICATION BOUNDS (§10 + PARAMS.md#RWA_EVENT_WITHDRAW_FRAC): the keeper ONLY
// flags the window. The Vault enforces the forced widen / partial withdraw up to the
// HARDCODED bound RWA_EVENT_WITHDRAW_FRAC = 0.80 (8000 bps), keeper-scoped within
// {RWA_OFFHOURS_WITHDRAW_FRAC .. 9000} for the current session only. The keeper cannot set
// the fraction — it cannot exceed the bound by construction (INV-12).
//
// FAIL-STATIC (§10 + PARAMS.md): "flag absent ⇒ normal q" — if this keeper is down, the pool
// simply uses the off-hours baseline q = 0.60 (PT-7). A stale flag cannot persist beyond the
// session: the Vault scopes the flag to the current session on-chain, and this keeper also
// CLEARS flags outside their window (belt-and-braces).
//
// CALENDAR SOURCE: env KEEPER_EVENT_CALENDAR (JSON), exogenous like the market-hours holiday
// calendar. Shape: [{ "poolId": "0x…", "date": "YYYY-MM-DD", "kind": "earnings" }] — the
// event window is the SESSION CLOSE preceding the event date's open (i.e. flag from the
// prior close through the event-day open). TODO(deploy): wire a real earnings-calendar feed.

import { FeraVaultAbi } from "../abis/FeraVault";
import { runOnce, log, isUnset, type KeeperEnv } from "./common";
import type { Hex } from "../pipeline/types";

export interface CalendarEvent {
  poolId: Hex;
  date: string; // ISO "YYYY-MM-DD" (event day, exchange time)
  kind: string; // "earnings" | "corporate-action" | ...
}

function loadCalendar(): CalendarEvent[] {
  const raw = process.env.KEEPER_EVENT_CALENDAR;
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as CalendarEvent[];
    return parsed.filter((e) => typeof e.poolId === "string" && e.poolId.length === 66 && !!e.date);
  } catch {
    return [];
  }
}

/**
 * Pure window decision (unit-testable, no chain): is `now` inside the event guard window for
 * an event on `eventDate`? Window = [event-day 00:00 UTC − preOpenHours, event-day open].
 * Default: from 20:00 UTC the PRIOR day (US close) through 13:30 UTC event day (US open) —
 * i.e. the session close BEFORE the event carries the elevated withdraw fraction.
 */
export function inEventWindow(
  now: Date,
  eventDate: string,
  session = { priorCloseUtcMin: 20 * 60, openUtcMin: 13 * 60 + 30 },
): boolean {
  const dayStartMs = Date.parse(`${eventDate}T00:00:00Z`);
  if (Number.isNaN(dayStartMs)) return false;
  const windowStart = dayStartMs - (24 * 60 - session.priorCloseUtcMin) * 60_000; // prior close
  const windowEnd = dayStartMs + session.openUtcMin * 60_000; // event-day open
  const t = now.getTime();
  return t >= windowStart && t < windowEnd;
}

function rwaPools(): Hex[] {
  const raw = process.env.KEEPER_RWA_POOLS;
  if (!raw) return [];
  return raw.split(",").map((s) => s.trim() as Hex).filter((s) => s.length === 66);
}

async function tick(env: KeeperEnv): Promise<void> {
  const vault = process.env.FERA_VAULT_ADDRESS;
  if (isUnset(vault)) {
    log("event-calendar", "warn", "FERA_VAULT_ADDRESS unset — skipping (fail-static)");
    return;
  }
  const calendar = loadCalendar();
  const now = new Date();
  const pools = rwaPools();
  log("event-calendar", "info", "loaded calendar", { events: calendar.length, pools: pools.length });

  for (const poolId of pools) {
    const events = calendar.filter((e) => e.poolId.toLowerCase() === poolId.toLowerCase());
    const desired = events.some((e) => inEventWindow(now, e.date));

    // Read the on-chain flag; only submit when it disagrees (idempotent; also CLEARS stale
    // flags outside any window — fail-static means the un-flagged state is always safe).
    const onchain = (await env.publicClient.readContract({
      address: vault as `0x${string}`,
      abi: FeraVaultAbi,
      functionName: "isEventWindow",
      args: [poolId],
    })) as boolean;
    if (onchain === desired) continue;

    if (env.dryRun || !env.walletClient || !env.account) {
      log("event-calendar", "info", "DRY-RUN would setEventWindow", { poolId, active: desired });
      continue;
    }
    const hash = await env.walletClient.writeContract({
      chain: null,
      account: env.account,
      address: vault as `0x${string}`,
      abi: FeraVaultAbi,
      functionName: "setEventWindow",
      args: [poolId, desired],
    });
    log("event-calendar", "info", "setEventWindow submitted (Vault bounds q ≤ 0.80 on-chain)", {
      poolId,
      active: desired,
      hash,
    });
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runOnce("event-calendar", tick).then((code) => process.exit(code));
}

export { tick as eventCalendarTick };
