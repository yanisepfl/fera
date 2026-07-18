"use client";

import Link from "next/link";
import type { PoolSummary, MarketHoursState } from "@/lib/types";
import { LiveFee } from "./LiveFee";
import { DepositDialog } from "./DepositDialog";
import { LiveDot } from "@/components/ui/LiveDot";
import { RegimeBadge } from "@/components/ui/Badge";
import { TokenPair } from "@/components/ui/TokenPair";
import { Button } from "@/components/ui/Button";
import { useLiveFee } from "@/lib/hooks/useLiveFee";
import { feeReason, TONE_COLOR } from "@/lib/feeReason";
import { apr, usdCompact, usdPrice, signedPct, multiple, num, tokenAmt } from "@/lib/format";

/**
 * Earn-home centerpiece: one flagship pool with its LIVE dynamic fee as the hero
 * number, the WHY beneath it, the APY split (fee-yield vs emissions), TVL, and the
 * depth claim ("deepest NVDA/USDG pool"). 2-click deposit inline.
 *
 * PRE-LAUNCH LIVE MODE (`vaultLive === false`): the vault fee doesn't exist, so the
 * hero number becomes the pool's REAL market price (with its real 24h move), the stats
 * become the venue's real TVL / volume / trade count, and every vault economic is a
 * quiet "opens at launch" — no simulated fee, no invented APRs.
 */
export function LiveFeeHero({
  pool,
  marketState,
  depthLabel,
}: {
  pool: PoolSummary;
  marketState?: MarketHoursState | null;
  depthLabel: string;
}) {
  const vaultLive = pool.vaultLive !== false;
  // REAL on-chain fee (pool.chain.feeLive): print it verbatim — the mock walk stays off.
  const feeLive = pool.chain?.feeLive === true;
  const statsPending = pool.chain?.statsPending === true;
  // Read the same live value the hero prints so the "why" tracks the number.
  const { pips: walkPips } = useLiveFee(
    pool.currentFeePips,
    pool.regime,
    1600,
    vaultLive && !feeLive
  );
  const pips = feeLive ? pool.currentFeePips : walkPips;
  const reason = feeReason(pool.regime, pips, marketState);

  if (!vaultLive) return <MarketHero pool={pool} />;

  return (
    <div className="relative overflow-hidden rounded-lg border border-line bg-card shadow-glow-accent">
      <div
        className="pointer-events-none absolute -right-24 -top-24 h-64 w-64 rounded-full opacity-[0.08] blur-3xl"
        style={{ background: "var(--accent)" }}
      />
      <div className="grid gap-6 p-6 md:grid-cols-[1.2fr_1fr] md:p-8">
        {/* left: live fee hero */}
        <div>
          <div className="mb-4 flex items-center gap-3">
            <TokenPair token0={pool.token0} token1={pool.token1} />
            <RegimeBadge regime={pool.regime} />
          </div>

          <div className="mb-1 flex items-center gap-2">
            <LiveDot label="LIVE FEE" />
            <span className="text-caption text-mute">
              {feeLive ? "read on-chain · updates ~8s" : "dynamic · updates every ~1s"}
            </span>
          </div>

          <LiveFee
            seedPips={pool.currentFeePips}
            regime={pool.regime}
            size="hero"
            simulate={!feeLive}
          />

          <div className="mt-4 flex items-start gap-2">
            <span
              className="mt-1.5 h-2 w-2 shrink-0 rounded-full"
              style={{ background: TONE_COLOR[reason.tone] }}
            />
            <div>
              <div
                className="text-body font-medium"
                style={{ color: TONE_COLOR[reason.tone] }}
              >
                {reason.headline}
              </div>
              <p className="mt-0.5 max-w-md text-body-sm text-dim">
                {reason.detail}
              </p>
            </div>
          </div>
        </div>

        {/* right: economics + deposit */}
        <div className="flex flex-col justify-between gap-5 rounded-lg border border-line bg-well/60 p-5">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <div className="overline mb-1">Fee-yield APR</div>
              <div className="font-mono tnum text-title font-semibold text-pos">
                {statsPending ? <span className="text-mute">—</span> : apr(pool.feeApr)}
              </div>
              <div className="text-caption text-mute">
                {statsPending ? "arrives with the indexer" : "after fees"}
              </div>
            </div>
            <div>
              <div className="overline mb-1">Emissions APR</div>
              <div className="font-mono tnum text-title font-semibold text-accent">
                {statsPending ? <span className="text-mute">—</span> : apr(pool.emissionsApr)}
              </div>
              <div className="text-caption text-mute">
                {statsPending ? "arrives with the indexer" : "esFERA · vests 6mo"}
              </div>
            </div>
            <div>
              <div className="overline mb-1">{statsPending ? "Vault NAV" : "TVL"}</div>
              <div className="font-mono tnum text-heading font-semibold text-text">
                {statsPending ? (
                  pool.chain?.navQuote !== undefined ? (
                    <>
                      {tokenAmt(pool.chain.navQuote, 4)}{" "}
                      <span className="text-caption text-dim">
                        {pool.chain.quoteSymbol}
                      </span>
                    </>
                  ) : (
                    <span className="text-mute">—</span>
                  )
                ) : (
                  usdCompact(pool.tvlUsd)
                )}
              </div>
              {statsPending ? (
                <div className="text-caption text-mute">read on-chain</div>
              ) : null}
            </div>
            <div>
              <div className="overline mb-1">Depth vs best</div>
              <div className="font-mono tnum text-heading font-semibold text-text">
                {statsPending ? <span className="text-mute">—</span> : multiple(pool.depthVsBest)}
              </div>
              {statsPending ? null : (
                <div className="text-caption text-pos">{depthLabel}</div>
              )}
            </div>
          </div>

          <div className="flex gap-2">
            <DepositDialog
              pool={pool}
              trigger={(open) => (
                <Button size="lg" className="flex-1" onClick={open}>
                  Deposit
                </Button>
              )}
            />
            <Link href={`/app/pool/${pool.poolId}`}>
              <Button size="lg" variant="secondary">
                Details
              </Button>
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}

/**
 * Pre-launch hero: the REAL market the vault will run. Price/volume/TVL/trades are
 * live Robinhood Chain data (via the backend's GeckoTerminal feed, ~60s cache);
 * vault economics show as "opens at launch". Nothing here is simulated.
 */
function MarketHero({ pool }: { pool: PoolSummary }) {
  const m = pool.market;
  const chg = m?.priceChange24h ?? 0;
  const up = chg >= 0;

  return (
    <div className="relative overflow-hidden rounded-lg border border-line bg-card shadow-glow-accent">
      <div
        className="pointer-events-none absolute -right-24 -top-24 h-64 w-64 rounded-full opacity-[0.08] blur-3xl"
        style={{ background: "var(--accent)" }}
      />
      <div className="grid gap-6 p-6 md:grid-cols-[1.2fr_1fr] md:p-8">
        {/* left: live market price hero */}
        <div>
          <div className="mb-4 flex items-center gap-3">
            <TokenPair token0={pool.token0} token1={pool.token1} />
            <RegimeBadge regime={pool.regime} />
          </div>

          <div className="mb-1 flex items-center gap-2">
            <LiveDot label="LIVE MARKET" color="var(--accent2)" />
            <span className="text-caption text-mute">
              Robinhood Chain{m ? ` · ${m.dexLabel}` : ""} · refreshes ~1min
            </span>
          </div>

          <div className="flex items-end gap-3">
            <span className="font-mono tnum text-hero font-semibold leading-none text-text">
              {m ? usdPrice(m.priceUsd) : "—"}
            </span>
            {m ? (
              <span
                className="mb-2 font-mono tnum text-body-sm font-semibold"
                style={{ color: up ? "var(--pos)" : "var(--neg)" }}
              >
                {up ? "▲" : "▼"} {signedPct(chg, 1)} 24h
              </span>
            ) : null}
          </div>

          <div className="mt-4 flex items-start gap-2">
            <span
              className="mt-1.5 h-2 w-2 shrink-0 rounded-full"
              style={{ background: "var(--accent)" }}
            />
            <div>
              <div className="text-body font-medium text-accent">
                Vault opens at launch
              </div>
              <p className="mt-0.5 max-w-md text-body-sm text-dim">
                This is the live market FERA will make — real price, volume and
                liquidity from Robinhood Chain. The dynamic fee, vault yield and FERA
                rewards switch on when the contracts deploy.
              </p>
            </div>
          </div>
        </div>

        {/* right: real market stats + honest vault placeholder */}
        <div className="flex flex-col justify-between gap-5 rounded-lg border border-line bg-well/60 p-5">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <div className="overline mb-1">Market TVL</div>
              <div className="font-mono tnum text-title font-semibold text-text">
                {m ? usdCompact(m.tvlUsd) : "—"}
              </div>
              <div className="text-caption text-mute">this pool, on-chain</div>
            </div>
            <div>
              <div className="overline mb-1">24h volume</div>
              <div className="font-mono tnum text-title font-semibold text-text">
                {m ? usdCompact(m.volume24hUsd) : "—"}
              </div>
              <div className="text-caption text-mute">real trades</div>
            </div>
            <div>
              <div className="overline mb-1">24h trades</div>
              <div className="font-mono tnum text-heading font-semibold text-text">
                {m ? num(m.txns24h) : "—"}
              </div>
            </div>
            <div>
              <div className="overline mb-1">Vault APR</div>
              <div className="font-mono tnum text-heading font-semibold text-mute">—</div>
              <div className="text-caption text-mute">opens at launch</div>
            </div>
          </div>

          <div className="flex gap-2">
            <DepositDialog
              pool={pool}
              trigger={(open) => (
                <Button size="lg" variant="secondary" className="flex-1" onClick={open}>
                  Deposits open at launch
                </Button>
              )}
            />
            <Link href={`/app/pool/${pool.poolId}`}>
              <Button size="lg" variant="secondary">
                Details
              </Button>
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}
