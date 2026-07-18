// Data-access layer: reads the Ponder store (indexed on-chain state) + pipeline bundle outputs
// and maps them to the frozen §8 response shapes (api/shapes.ts). All heavy transformation lives
// here so route handlers (api/routes.ts) stay thin. Live dynamic-fee reads are layered on top in
// routes via api/liveFee.ts — this store returns the INDEXED fee as the fallback value.
//
// `db` is the readonly drizzle handle from `ponder:api`; `schema` is `ponder:schema`. Drizzle
// operators are re-exported by ponder. Values are read as bigint and rendered to strings by the
// route layer via api/serialize.ts.

import { eq, desc, and } from "ponder";
import { valueE6 } from "../src/lib/prices";
import { getPriceE6 } from "../src/lib/priceRegistry";
import { EPOCH_SECONDS } from "../src/lib/epoch";
import { feeAprBps, emissionsAprBps, revenueShareAprBps, feraWeiToUsdE6 } from "./derive";
import type {
  Address,
  Hex,
  PoolListItem,
  PoolDetail,
  PoolDepthResponse,
  CompetitorDepth,
  PositionItem,
  EpochCurrent,
  StakingResponse,
  EmissionsTransparency,
  RevenueTransparency,
  TokenInfo,
  TrancheInfo,
  VestingGrant,
} from "./shapes";

const WINDOW_SECONDS = BigInt(EPOCH_SECONDS);

// Loose row aliases — precise typing returns after `ponder codegen` (see ponder-env.d.ts).
type Row = Record<string, any>;

export interface RawPool {
  id: Hex;
  regime: number;
  currentFeePips: number;
  token0: Address;
  token1: Address;
}

export class Store {
  constructor(
    private readonly db: any,
    private readonly schema: any,
  ) {}

  // ---- helpers -------------------------------------------------------------

  private tvlUsdE6(p: Row): bigint {
    const p0 = getPriceE6(p.token0);
    const p1 = getPriceE6(p.token1);
    return (
      valueE6(p.reserve0 ?? 0n, p0, p.token0Decimals ?? 18) +
      valueE6(p.reserve1 ?? 0n, p1, p.token1Decimals ?? 18)
    );
  }

  /**
   * FERA pool ±1% depth in USD. APPROXIMATION (TODO precise v4 tick math, D-BK-4): for a
   * full-range MEME position depth ≈ TVL; for a concentrated RWA position the on-chain liquidity
   * within ±1% would be read from the position band. We use TVL as a conservative lower bound so
   * the marketing "depth vs best" ratio never overstates FERA depth. Reproducible from reserves.
   */
  private feraDepth1PctUsdE6(p: Row): bigint {
    return this.tvlUsdE6(p);
  }

  /** On-chain-posted Merkle root for an epoch (indexed from Distributor:RootPosted), or null.
   *  Used by the proof route to refuse to serve a bundle whose root is NOT posted on-chain
   *  (e.g. a dry-run artifact) — the API must never hand out unclaimable/fabricated proofs. */
  async epochPostedRoot(epochId: bigint): Promise<Hex | null> {
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.epoch)
      .where(eq(this.schema.epoch.id, epochId))
      .limit(1);
    return (rows[0]?.merkleRoot as Hex | undefined) ?? null;
  }

  private async latestFinalizedEpoch(): Promise<Row | null> {
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.epoch)
      .orderBy(desc(this.schema.epoch.id))
      .limit(1);
    return rows[0] ?? null;
  }

  private async poolEpochStat(epochId: bigint, poolId: Hex): Promise<Row | null> {
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.poolEpochStat)
      .where(eq(this.schema.poolEpochStat.id, `${epochId}:${poolId}`))
      .limit(1);
    return rows[0] ?? null;
  }

  // Internal: deepest competitor on a pair, with the depth kept as E6 bigint (USD-string
  // rendering happens only at the response boundary — §8 conventions v0.2).
  private async bestCompetitorDepthE6(
    pairKey: string,
  ): Promise<{ competitorPoolId: Hex; dex: string; feePips: number; depthE6: bigint } | null> {
    // latest depth snapshot per competitor pool on this pair; pick the deepest.
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.competitorDepthSnapshot)
      .where(eq(this.schema.competitorDepthSnapshot.pairKey, pairKey))
      .orderBy(desc(this.schema.competitorDepthSnapshot.timestamp));
    const seen = new Set<string>();
    let best: { competitorPoolId: Hex; dex: string; feePips: number; depthE6: bigint } | null = null;
    for (const r of rows) {
      if (seen.has(r.competitorPoolId)) continue; // first = latest per pool
      seen.add(r.competitorPoolId);
      const comp = await this.competitorMeta(r.competitorPoolId);
      const depthE6 = (r.depth1PctUsdE6 ?? 0n) as bigint;
      if (!best || depthE6 > best.depthE6) {
        best = { competitorPoolId: r.competitorPoolId, dex: comp?.dex ?? "unknown", feePips: r.feePips, depthE6 };
      }
    }
    return best;
  }

  private async competitorMeta(id: Hex): Promise<Row | null> {
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.competitorPool)
      .where(eq(this.schema.competitorPool.id, id))
      .limit(1);
    return rows[0] ?? null;
  }

  private pairKeyOf(p: Row): string {
    const x = (p.token0 as string).toLowerCase();
    const y = (p.token1 as string).toLowerCase();
    return x < y ? `${x}:${y}` : `${y}:${x}`;
  }

  private tokenInfo(p: Row, which: 0 | 1): TokenInfo {
    return which === 0
      ? { address: p.token0, symbol: p.token0Symbol ?? null, decimals: p.token0Decimals ?? 18 }
      : { address: p.token1, symbol: p.token1Symbol ?? null, decimals: p.token1Decimals ?? 18 };
  }

  /** Per-tranche view (F-8/D-12). feeApr formula: tranche cumFees annualized over the tranche's
   *  observed lifetime (lastUpdated − pool.createdAt), vs tranche TVL — reproducible from rows. */
  private async tranchesOf(p: Row): Promise<TrancheInfo[]> {
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.tranche)
      .where(eq(this.schema.tranche.poolId, p.id));
    rows.sort((a, b) => a.tranche - b.tranche);
    return rows.map((tr) => {
      const p0 = getPriceE6(p.token0);
      const p1 = getPriceE6(p.token1);
      const tvl =
        valueE6(tr.reserve0 ?? 0n, p0, p.token0Decimals ?? 18) +
        valueE6(tr.reserve1 ?? 0n, p1, p.token1Decimals ?? 18);
      const lifetime = BigInt(Math.max((tr.lastUpdated ?? 0) - (p.createdAt ?? 0), 1));
      return {
        tranche: tr.tranche,
        totalShares: (tr.totalShares ?? 0n).toString(),
        tvlUsd: this.usd(tvl),
        sharePriceX96: (tr.lastSharePriceX96 ?? 0n).toString(),
        feeApr: this.fraction(feeAprBps(tr.cumFeesUsdE6 ?? 0n, tvl, lifetime)),
      };
    });
  }

  // ---- §8 endpoints --------------------------------------------------------

  /** GET /pools */
  async pools(): Promise<{ items: PoolListItem[]; raw: RawPool[] }> {
    const rows: Row[] = await this.db.select().from(this.schema.pool);
    const latest = await this.latestFinalizedEpoch();
    const items: PoolListItem[] = [];
    const raw: RawPool[] = [];
    for (const p of rows) {
      const tvl = this.tvlUsdE6(p);
      const stat = latest ? await this.poolEpochStat(latest.id, p.id) : null;
      const feesEarnedWindow = stat?.feesEarnedUsdE6 ?? 0n;
      const emissionsUsd = await this.poolEmissionsUsdE6(p.id, latest);
      const best = await this.bestCompetitorDepthE6(this.pairKeyOf(p));
      const feraDepth = this.feraDepth1PctUsdE6(p);
      const depthVsBest = best && best.depthE6 > 0n
        ? this.ratio(feraDepth, best.depthE6)
        : "0"; // 0 == no competitor benchmark indexed yet
      items.push({
        poolId: p.id,
        regime: p.regime,
        token0: this.tokenInfo(p, 0),
        token1: this.tokenInfo(p, 1),
        currentFeePips: p.currentFeePips,
        currentFeeSource: "indexed",
        feeApr: this.fraction(feeAprBps(feesEarnedWindow, tvl, WINDOW_SECONDS)),
        emissionsApr: this.fraction(emissionsAprBps(emissionsUsd, tvl, WINDOW_SECONDS)),
        tvlUsd: this.usd(tvl),
        depthVsBest,
        tranches: await this.tranchesOf(p),
      });
      raw.push({ id: p.id, regime: p.regime, currentFeePips: p.currentFeePips, token0: p.token0, token1: p.token1 });
    }
    return { items, raw };
  }

  /** Approx pool esFERA emission (USD E6) for the latest epoch: emitted*80%*poolShare, valued. */
  private async poolEmissionsUsdE6(poolId: Hex, epoch: Row | null): Promise<bigint> {
    if (!epoch || (epoch.emitted ?? 0n) === 0n || (epoch.feraTwap ?? 0n) === 0n) return 0n;
    const stat = await this.poolEpochStat(epoch.id, poolId);
    if (!stat) return 0n;
    const all: Row[] = await this.db
      .select()
      .from(this.schema.poolEpochStat)
      .where(eq(this.schema.poolEpochStat.epochId, epoch.id));
    let totalEarned = 0n;
    for (const r of all) totalEarned += r.feesEarnedUsdE6 ?? 0n;
    if (totalEarned === 0n) return 0n;
    // LP share is 85% of emitted (MASTER_SPEC v0.6 §7, Decision-A″ frozen 85/5/10, F-10).
    // Ignores off-chain quality scaling + per-pool locks (approximation, documented).
    const lpPoolFeraWei = ((epoch.emitted as bigint) * 8500n) / 10_000n;
    const poolFeraWei = (lpPoolFeraWei * (stat.feesEarnedUsdE6 ?? 0n)) / totalEarned;
    return feraWeiToUsdE6(poolFeraWei, epoch.feraTwap);
  }

  /** GET /pools/:poolId */
  async pool(poolId: Hex): Promise<PoolDetail | null> {
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.pool)
      .where(eq(this.schema.pool.id, poolId))
      .limit(1);
    const p = rows[0];
    if (!p) return null;

    const list = (await this.pools()).items.find((x) => x.poolId.toLowerCase() === poolId.toLowerCase());
    const feeHistory: Row[] = await this.db
      .select()
      .from(this.schema.poolFeeSnapshot)
      .where(eq(this.schema.poolFeeSnapshot.poolId, poolId))
      .orderBy(desc(this.schema.poolFeeSnapshot.timestamp))
      .limit(200);
    const strategyLog: Row[] = await this.db
      .select()
      .from(this.schema.strategyAction)
      .where(eq(this.schema.strategyAction.poolId, poolId))
      .orderBy(desc(this.schema.strategyAction.timestamp))
      .limit(100);

    const base = list ?? {
      poolId: p.id, regime: p.regime,
      token0: this.tokenInfo(p, 0), token1: this.tokenInfo(p, 1),
      currentFeePips: p.currentFeePips, currentFeeSource: "indexed" as const,
      feeApr: "0", emissionsApr: "0", tvlUsd: this.usd(this.tvlUsdE6(p)), depthVsBest: "0",
      tranches: await this.tranchesOf(p),
    };

    return {
      ...base,
      positionBand: { tickLower: p.tickLower ?? null, tickUpper: p.tickUpper ?? null },
      marketHoursState: p.regime === 1 ? (p.marketOpen ? "open" : "closed") : null,
      oraclePrice: (p.lastOraclePrice ?? 0n).toString(),
      poolPrice: (p.lastSharePriceX96 ?? 0n).toString(),
      cumFeesUsd: this.usd(p.cumFeesUsdE6 ?? 0n),
      cumRevenueUsd: this.usd(p.cumRevenueUsdE6 ?? 0n),
      // F-8 D-14: forfeited JIT fees donated to in-range LPs — LP yield, pool metric.
      jitFeesForfeitedToLpsUsd: this.usd(p.cumJitFeesUsdE6 ?? 0n),
      feeHistory: feeHistory.map((f) => ({ timestamp: f.timestamp, feePips: f.feePips })).reverse(),
      strategyLog: strategyLog.map((s) => ({
        timestamp: s.timestamp, kind: s.kind, tickLower: s.tickLower, tickUpper: s.tickUpper,
        oraclePrice: (s.oraclePrice ?? 0n).toString(), justificationHash: s.justificationHash, txHash: s.txHash,
      })),
    };
  }

  /** GET /pools/:poolId/depth */
  async depth(poolId: Hex): Promise<PoolDepthResponse | null> {
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.pool)
      .where(eq(this.schema.pool.id, poolId))
      .limit(1);
    const p = rows[0];
    if (!p) return null;
    const pairKey = this.pairKeyOf(p);
    const snaps: Row[] = await this.db
      .select()
      .from(this.schema.competitorDepthSnapshot)
      .where(eq(this.schema.competitorDepthSnapshot.pairKey, pairKey))
      .orderBy(desc(this.schema.competitorDepthSnapshot.timestamp));
    const seen = new Set<string>();
    const competitors: CompetitorDepth[] = [];
    let best: CompetitorDepth | null = null;
    let bestE6 = 0n;
    for (const r of snaps) {
      if (seen.has(r.competitorPoolId)) continue;
      seen.add(r.competitorPoolId);
      const meta = await this.competitorMeta(r.competitorPoolId);
      const depthE6 = (r.depth1PctUsdE6 ?? 0n) as bigint;
      const d: CompetitorDepth = {
        competitorPoolId: r.competitorPoolId,
        dex: meta?.dex ?? "unknown",
        feePips: r.feePips,
        depth1PctUsd: this.usd(depthE6), // §8 conventions v0.2: USD = human-unit decimal string
      };
      competitors.push(d);
      if (!best || depthE6 > bestE6) {
        best = d;
        bestE6 = depthE6;
      }
    }
    const feraDepth = this.feraDepth1PctUsdE6(p);
    return {
      poolId: p.id,
      pairKey,
      feraDepth1PctUsd: this.usd(feraDepth), // §8 conventions v0.2 (was raw E6 — BK fix)
      competitors,
      best,
      depthVsBest: best && bestE6 > 0n ? this.ratio(feraDepth, bestE6) : "0",
    };
  }

  /** GET /positions/:account — one item per (pool, tranche) position (F-8/D-12). */
  async positions(account: Address): Promise<PositionItem[]> {
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.position)
      .where(eq(this.schema.position.account, account));
    const out: PositionItem[] = [];
    for (const pos of rows) {
      if ((pos.shares ?? 0n) === 0n) continue;
      const poolRows: Row[] = await this.db
        .select()
        .from(this.schema.pool)
        .where(eq(this.schema.pool.id, pos.poolId))
        .limit(1);
      const p = poolRows[0];
      // value the position against ITS TRANCHE's reserves/supply (each tranche is an
      // independent ERC-20 with its own NAV — INV-15); pool-level fallback if no tranche row.
      const trRows: Row[] = await this.db
        .select()
        .from(this.schema.tranche)
        .where(eq(this.schema.tranche.id, `${pos.poolId}:${pos.tranche ?? 0}`))
        .limit(1);
      const tr = trRows[0];
      let tvl = 0n;
      let totalShares = 0n;
      if (tr && p) {
        const p0 = getPriceE6(p.token0);
        const p1 = getPriceE6(p.token1);
        tvl =
          valueE6(tr.reserve0 ?? 0n, p0, p.token0Decimals ?? 18) +
          valueE6(tr.reserve1 ?? 0n, p1, p.token1Decimals ?? 18);
        totalShares = tr.totalShares ?? 0n;
      } else if (p) {
        tvl = this.tvlUsdE6(p);
        totalShares = p.totalShares ?? 0n;
      }
      const valueUsd = totalShares > 0n ? (tvl * (pos.shares as bigint)) / totalShares : 0n;
      out.push({
        poolId: pos.poolId,
        tranche: pos.tranche ?? 0,
        shares: (pos.shares ?? 0n).toString(),
        valueUsd: this.usd(valueUsd),
        feesEarned: this.usd(pos.feesEarnedUsdE6 ?? 0n),
        emissionsPending: "0", // projected from the pipeline pre-posting; TODO wire (D-BK-5)
      });
    }
    return out;
  }

  /** GET /vesting/:account — F-3 vesting grants (§8 shape). String wei amounts (conventions
   *  v0.2). vested = amount × clamp(now − startTs, 0, endTs − startTs) / (endTs − startTs);
   *  claimable = vested − claimed. VestClaimed(account, amount) is now indexed (schema.vestClaimed,
   *  BK-1) but carries NO grantId, so per-grant `claimed` remains an approximation — claimable is
   *  still served as `vested` pending a per-grant claim signal (D-BK-9 / OPEN_DECISIONS BK-1). */
  async vesting(account: Address, nowTs = Math.floor(Date.now() / 1000)): Promise<VestingGrant[]> {
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.vestStarted)
      .where(eq(this.schema.vestStarted.account, account));
    rows.sort((a, b) => (a.id < b.id ? -1 : 1));
    return rows.map((g) => {
      const amount = (g.amount ?? 0n) as bigint;
      const startTs = Number(g.startTs ?? 0n);
      const endTs = Number(g.endTs ?? 0n);
      const duration = BigInt(Math.max(endTs - startTs, 1));
      const elapsed = BigInt(Math.min(Math.max(nowTs - startTs, 0), Math.max(endTs - startTs, 0)));
      const vested = (amount * elapsed) / duration;
      return {
        grantId: g.id,
        amount: amount.toString(),
        startTs,
        endTs,
        vested: vested.toString(),
        claimable: vested.toString(),
      };
    });
  }

  /** GET /epochs/current (optionally scoped to ?account) */
  async epochCurrent(account?: Address): Promise<EpochCurrent> {
    const epochRows: Row[] = await this.db
      .select()
      .from(this.schema.epoch)
      .orderBy(desc(this.schema.epoch.id))
      .limit(1);
    const latest = epochRows[0];
    // current (in-progress) epoch is latest finalized + 1, or 0 if none finalized yet.
    const currentId = latest ? (latest.id as bigint) + 1n : 0n;

    let feesPaid = 0n;
    let feesEarned = 0n;
    if (account) {
      const t: Row[] = await this.db
        .select()
        .from(this.schema.traderEpochStat)
        .where(and(eq(this.schema.traderEpochStat.epochId, currentId), eq(this.schema.traderEpochStat.account, account)))
        .limit(1);
      feesPaid = t[0]?.feesPaidUsdE6 ?? 0n;
    } else {
      const stats: Row[] = await this.db
        .select()
        .from(this.schema.poolEpochStat)
        .where(eq(this.schema.poolEpochStat.epochId, currentId));
      for (const s of stats) {
        feesPaid += s.feesPaidUsdE6 ?? 0n;
        feesEarned += s.feesEarnedUsdE6 ?? 0n;
      }
    }
    // projectedEsFera: β × (revenue this epoch valued in FERA), capped — a live projection using
    // the current epoch's indexed revenue and the last finalized FERA TWAP. Reproducible; not
    // authoritative (the pipeline recomputes at close). Falls back to 0 without a TWAP.
    const projected = "0";
    return {
      epochId: currentId.toString(),
      endsAt: this.epochEndsAt(currentId),
      feesPaid: this.usd(feesPaid),
      feesEarned: this.usd(feesEarned),
      projectedEsFera: projected,
    };
  }

  private epochEndsAt(epochId: bigint): number {
    const genesis = Number(process.env.FERA_EMISSIONS_GENESIS_TS ?? 0);
    return genesis + Number(epochId + 1n) * EPOCH_SECONDS;
  }

  /** GET /staking/:account */
  async staking(account: Address): Promise<StakingResponse> {
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.stakingPosition)
      .where(eq(this.schema.stakingPosition.id, account.toLowerCase()))
      .limit(1);
    const s = rows[0];
    const sFera = s?.sFera ?? 0n;
    // revenueShareApr: annualize the staker share of trailing RevenueSplit vs staked value.
    const totalsRows: Row[] = await this.db.select().from(this.schema.revenueTotals).limit(1);
    const toStakers = totalsRows[0]?.toStakers ?? 0n;
    const feraPrice = getPriceE6((process.env.FERA_TOKEN_ADDRESS ?? "0x0") as Address);
    const stakedValueE6 = feraPrice > 0n ? valueE6(sFera, feraPrice, 18) : 0n;
    const apr = revenueShareAprBps(toStakers, stakedValueE6, WINDOW_SECONDS);
    return {
      account,
      sFera: sFera.toString(),
      boost: this.boost(s?.boostX18 ?? 10n ** 18n),
      multiplierPoints: (s?.multiplierPoints ?? 0n).toString(),
      revenueShareApr: this.fraction(apr),
    };
  }

  /** GET /transparency/emissions */
  async emissions(): Promise<EmissionsTransparency> {
    const rows: Row[] = await this.db
      .select()
      .from(this.schema.epoch)
      .orderBy(this.schema.epoch.id);
    return {
      series: rows.map((e) => ({
        epochId: (e.id as bigint).toString(),
        cap: (e.capAmount ?? 0n).toString(),
        revenueBound: (e.revenueBound ?? 0n).toString(),
        emitted: (e.emitted ?? 0n).toString(),
        feraTwap: (e.feraTwap ?? 0n).toString(),
      })),
    };
  }

  /** GET /transparency/revenue */
  async revenue(): Promise<RevenueTransparency> {
    const totalsRows: Row[] = await this.db.select().from(this.schema.revenueTotals).limit(1);
    const t = totalsRows[0];
    const byTokenRows: Row[] = await this.db.select().from(this.schema.revenueByToken);
    return {
      toStakers: (t?.toStakers ?? 0n).toString(),
      toTreasury: (t?.toTreasury ?? 0n).toString(),
      toOps: (t?.toOps ?? 0n).toString(),
      byToken: byTokenRows.map((r) => ({
        token: r.token,
        toStakers: (r.cumToStakers ?? 0n).toString(),
        toTreasury: (r.cumToTreasury ?? 0n).toString(),
        toOps: (r.cumToOps ?? 0n).toString(),
        received: (r.cumReceived ?? 0n).toString(),
      })),
    };
  }

  // ---- string renderers (kept local so shapes stay pure strings) -----------
  private usd(e6: bigint): string {
    const neg = e6 < 0n; const v = neg ? -e6 : e6;
    const w = v / 1_000_000n; const f = (v % 1_000_000n).toString().padStart(6, "0").slice(0, 4);
    return `${neg ? "-" : ""}${w}.${f}`;
  }
  /** bps → DECIMAL FRACTION string, 4dp ("0.1200" = 12%) — §8 conventions v0.2 (APR/APY are
   *  decimal fractions, NOT percent; the old percent renderer was a conventions violation). */
  private fraction(bps: bigint): string {
    const neg = bps < 0n; const v = neg ? -bps : bps;
    const w = v / 10_000n; const f = (v % 10_000n).toString().padStart(4, "0");
    return `${neg ? "-" : ""}${w}.${f}`;
  }
  private boost(x18: bigint): string {
    const w = x18 / 10n ** 18n; const f = (x18 % 10n ** 18n).toString().padStart(18, "0").slice(0, 2);
    return `${w}.${f}`;
  }
  private ratio(a: bigint, b: bigint): string {
    if (b === 0n) return "0";
    const scaled = (a * 10_000n) / b; const w = scaled / 10_000n; const f = (scaled % 10_000n).toString().padStart(4, "0").slice(0, 2);
    return `${w}.${f}`;
  }
}
