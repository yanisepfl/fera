// KEEPER 1/4 — RWA market-hours / holiday flag (MASTER_SPEC §10).
//
// TRIGGER: schedule + holiday calendar (run each minute near session open/close).
// ACTION: flip the per-pool market-open flag via FeraVault.setHolidayFlag(poolId, isHoliday).
//
// ON-CHAIN VERIFICATION BOUNDS (§10): "Vault verifies hours against an on-chain schedule; keeper
// only flips a flag within bounds." The keeper does NOT decide fees — it toggles a boolean the
// Vault reads. The Vault clamps to its own on-chain trading-calendar/hysteresis; a wrong or
// missing flip cannot open trading outside the on-chain schedule, and if this keeper is absent the
// Vault holds the last state (fail-static, §10). Both keeper providers may flip — the write is
// idempotent (setting the same flag twice is a no-op on-chain).
//
// The holiday calendar itself is exogenous data (NYSE/Nasdaq sessions + holidays). It is loaded
// from an env-provided calendar (KEEPER_MARKET_CALENDAR json) or a calendar service; the Vault is
// the authority, this is a convenience trigger. TODO(deploy): wire the real calendar source.

import { FeraVaultAbi } from "../abis/FeraVault";
import { runOnce, log, isUnset, type KeeperEnv } from "./common";
import type { Hex } from "../pipeline/types";

interface Session {
  // minutes since UTC midnight for regular US equity session (13:30–20:00 UTC ≈ 9:30–16:00 ET).
  openUtcMin: number;
  closeUtcMin: number;
}
const DEFAULT_SESSION: Session = { openUtcMin: 13 * 60 + 30, closeUtcMin: 20 * 60 };

interface Calendar {
  holidays: string[]; // ISO dates "YYYY-MM-DD" the market is closed
  session: Session;
}

function loadCalendar(): Calendar {
  const raw = process.env.KEEPER_MARKET_CALENDAR;
  if (raw) {
    try {
      const p = JSON.parse(raw) as Partial<Calendar>;
      return { holidays: p.holidays ?? [], session: p.session ?? DEFAULT_SESSION };
    } catch {
      /* fall through to default */
    }
  }
  return { holidays: [], session: DEFAULT_SESSION };
}

/** Pure schedule decision (unit-testable, no chain): is the US equity market open at `now`? */
export function isMarketOpen(now: Date, cal: Calendar): boolean {
  const dow = now.getUTCDay(); // 0 Sun .. 6 Sat
  if (dow === 0 || dow === 6) return false;
  const iso = now.toISOString().slice(0, 10);
  if (cal.holidays.includes(iso)) return false;
  const min = now.getUTCHours() * 60 + now.getUTCMinutes();
  return min >= cal.session.openUtcMin && min < cal.session.closeUtcMin;
}

function rwaPools(): Hex[] {
  const raw = process.env.KEEPER_RWA_POOLS;
  if (!raw) return [];
  return raw.split(",").map((s) => s.trim() as Hex).filter((s) => s.length === 66);
}

async function tick(env: KeeperEnv): Promise<void> {
  const vault = process.env.FERA_VAULT_ADDRESS;
  if (isUnset(vault)) {
    log("market-hours", "warn", "FERA_VAULT_ADDRESS unset — skipping (fail-static)");
    return;
  }
  const cal = loadCalendar();
  const open = isMarketOpen(new Date(), cal);
  const pools = rwaPools();
  log("market-hours", "info", "computed session", { open, pools: pools.length });

  for (const poolId of pools) {
    // Read the on-chain flag; only submit if it disagrees (idempotent, saves gas).
    const onchainOpen = (await env.publicClient.readContract({
      address: vault as `0x${string}`,
      abi: FeraVaultAbi,
      functionName: "isMarketOpen",
      args: [poolId],
    })) as boolean;
    const desiredHoliday = !open;
    if (onchainOpen === open) continue; // already correct
    if (env.dryRun || !env.walletClient || !env.account) {
      log("market-hours", "info", "DRY-RUN would setHolidayFlag", { poolId, isHoliday: desiredHoliday });
      continue;
    }
    const hash = await env.walletClient.writeContract({
      chain: null,
      account: env.account,
      address: vault as `0x${string}`,
      abi: FeraVaultAbi,
      functionName: "setHolidayFlag",
      args: [poolId, desiredHoliday],
    });
    log("market-hours", "info", "setHolidayFlag submitted", { poolId, isHoliday: desiredHoliday, hash });
  }
}

// Standalone entry (npm run keeper:market-hours). Also imported by tests for isMarketOpen().
if (import.meta.url === `file://${process.argv[1]}`) {
  runOnce("market-hours", tick).then((code) => process.exit(code));
}

export { tick as marketHoursTick };
