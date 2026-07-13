// Epoch aggregation (MASTER_SPEC §9 "Inputs" → weights).
//
//  - fees PAID per trader        : sum of Swap.feeAmount (input token) valued E6, per pool.
//  - fees EARNED per LP          : net LP fees (fee - perfFee) attributed to holders by
//                                  share-seconds over each accrual interval. F-8/D-12: shares
//                                  are per (pool, TRANCHE) ERC-20s and a band's fees accrue
//                                  solely to its owning tranche (INV-15), so the attribution
//                                  stream runs PER (pool, tranche) — deposits, withdraws,
//                                  share TRANSFERS and FeesCollected of one tranche never
//                                  touch another tranche's holders. Weights are then merged
//                                  per (pool, account) for the emission leaf (leaves are
//                                  pool-scoped, not tranche-scoped).
//  - revenue                     : sum of perf fees (the 10% skim) valued E6.
//  - share-seconds               : epoch-wide per (pool, tranche, account) — input to the
//                                  trader-leaf cluster-share test (MECHANISM_SPEC §4.7:
//                                  "cluster holds ≥ 5% of the pool's vault shares", measured
//                                  time-weighted over the epoch so end-of-epoch dodging is
//                                  ineffective).
//
// Deterministic integer math only. Output weights are E6 (micro-dollars).

import { valueE6, inputToken } from "../src/lib/prices";
import type {
  EpochSnapshot,
  PoolPricing,
  SwapEventInput,
  ShareTransferInput,
  Hex,
  Address,
} from "./types";

export interface TrancheShareSeconds {
  tranche: number;
  perAccount: Map<Address, bigint>; // epoch-wide share-seconds
  total: bigint;
}

export interface PoolAggregate {
  poolId: Hex;
  regime: number | null;
  feesPaidE6: bigint;
  feesEarnedE6: bigint;
  revenueE6: bigint;
  traderWeightE6: Map<Address, bigint>; // fees paid per trader in this pool
  lpWeightE6: Map<Address, bigint>; // fees earned per LP in this pool (merged across tranches)
  shareSeconds: TrancheShareSeconds[]; // epoch-wide, per tranche (cluster-share test input)
  unattributedFeesE6: bigint; // fees that accrued while totalShares == 0 (diagnostic)
}

export interface AggregateResult {
  pools: Map<Hex, PoolAggregate>;
  revenueE6: bigint; // protocol revenue (perf fees) valued E6, all pools
  totalFeesPaidE6: bigint;
  totalFeesEarnedE6: bigint;
}

function pricingFor(snapshot: EpochSnapshot, poolId: Hex): PoolPricing {
  const p = snapshot.pools.find((x) => x.poolId.toLowerCase() === poolId.toLowerCase());
  if (!p) throw new Error(`aggregate: no pricing for pool ${poolId}`);
  return p;
}

function addTo(map: Map<Address, bigint>, key: Address, v: bigint) {
  if (v <= 0n) return;
  map.set(key, (map.get(key) ?? 0n) + v);
}

/** Value a single swap's LP fee (input token) to E6. */
export function swapFeeE6(swap: SwapEventInput, pricing: PoolPricing): bigint {
  const inTok = inputToken(swap.zeroForOne, pricing.token0.address, pricing.token1.address);
  if (inTok.toLowerCase() === pricing.token0.address.toLowerCase()) {
    return valueE6(swap.feeAmount, pricing.price0E6, pricing.token0.decimals);
  }
  return valueE6(swap.feeAmount, pricing.price1E6, pricing.token1.decimals);
}

// A merged, time-ordered stream item for one (pool, tranche) attribution run.
type StreamItem =
  | { t: number; li: number; kind: "dep"; account: Address; shares: bigint }
  | { t: number; li: number; kind: "wd"; account: Address; shares: bigint }
  | { t: number; li: number; kind: "xfer"; from: Address; to: Address; shares: bigint }
  | { t: number; li: number; kind: "fee"; netE6: bigint };

/**
 * Attribute one (pool, tranche)'s net LP fees to holders by share-seconds over each accrual
 * interval. Between consecutive stream events the balances are constant; each FeesCollected
 * distributes the fees that accrued since the previous FeesCollected pro-rata to the
 * share-seconds each holder accumulated over that window. Share ERC-20 transfers move the
 * balance (and therefore future accrual) from `from` to `to` at the transfer instant.
 * Additionally accumulates EPOCH-WIDE share-seconds (never reset) up to `epochEndTs`.
 */
function attributeTranche(
  pool: PoolAggregate,
  pricing: PoolPricing,
  tranche: number,
  opening: { account: Address; shares: bigint }[],
  deposits: EpochSnapshot["deposits"],
  withdraws: EpochSnapshot["withdraws"],
  fees: EpochSnapshot["feesCollected"],
  transfers: ShareTransferInput[],
  epochEndTs?: number,
) {
  const balance = new Map<Address, bigint>();
  let totalShares = 0n;
  for (const b of opening) {
    balance.set(b.account, (balance.get(b.account) ?? 0n) + b.shares);
    totalShares += b.shares;
  }

  const stream: StreamItem[] = [];
  for (const d of deposits)
    stream.push({ t: d.timestamp, li: d.logIndex, kind: "dep", account: d.user, shares: d.sharesMinted });
  for (const w of withdraws)
    stream.push({ t: w.timestamp, li: w.logIndex, kind: "wd", account: w.user, shares: w.sharesBurned });
  for (const x of transfers)
    stream.push({ t: x.timestamp, li: x.logIndex, kind: "xfer", from: x.from, to: x.to, shares: x.shares });
  for (const f of fees) {
    const netE6 =
      valueE6(f.fee0 - f.perfFee0, pricing.price0E6, pricing.token0.decimals) +
      valueE6(f.fee1 - f.perfFee1, pricing.price1E6, pricing.token1.decimals);
    stream.push({ t: f.timestamp, li: f.logIndex, kind: "fee", netE6 });
  }
  stream.sort((a, b) => (a.t !== b.t ? a.t - b.t : a.li - b.li));

  // window share-seconds (reset at each fee booking) + epoch-wide share-seconds (never reset)
  const windowSS = new Map<Address, bigint>();
  let windowTotalSS = 0n;
  const epochSS = new Map<Address, bigint>();
  let epochTotalSS = 0n;
  let lastTs = stream.length > 0 ? stream[0]!.t : 0;

  const accrue = (now: number) => {
    if (now <= lastTs || totalShares === 0n) {
      lastTs = Math.max(lastTs, now);
      return;
    }
    const dt = BigInt(now - lastTs);
    for (const [acc, bal] of balance) {
      if (bal <= 0n) continue;
      const ss = bal * dt;
      windowSS.set(acc, (windowSS.get(acc) ?? 0n) + ss);
      windowTotalSS += ss;
      epochSS.set(acc, (epochSS.get(acc) ?? 0n) + ss);
      epochTotalSS += ss;
    }
    lastTs = now;
  };

  for (const it of stream) {
    accrue(it.t); // credit share-seconds up to this event at pre-event balances
    if (it.kind === "dep") {
      balance.set(it.account, (balance.get(it.account) ?? 0n) + it.shares);
      totalShares += it.shares;
    } else if (it.kind === "wd") {
      const cur = balance.get(it.account) ?? 0n;
      const dec = cur < it.shares ? cur : it.shares; // clamp (defensive)
      balance.set(it.account, cur - dec);
      totalShares -= dec;
    } else if (it.kind === "xfer") {
      const cur = balance.get(it.from) ?? 0n;
      const moved = cur < it.shares ? cur : it.shares; // clamp (defensive)
      balance.set(it.from, cur - moved);
      balance.set(it.to, (balance.get(it.to) ?? 0n) + moved);
      // totalShares unchanged
    } else {
      // distribute this fee booking pro-rata to share-seconds accumulated so far
      if (windowTotalSS === 0n) {
        pool.unattributedFeesE6 += it.netE6;
      } else {
        for (const [acc, ss] of windowSS) {
          const share = (it.netE6 * ss) / windowTotalSS;
          if (share > 0n) addTo(pool.lpWeightE6, acc, share);
        }
      }
      pool.feesEarnedE6 += it.netE6;
      windowSS.clear();
      windowTotalSS = 0n;
    }
  }
  // tail accrual to epoch close so the cluster-share test sees full-epoch holdings
  if (epochEndTs !== undefined) accrue(epochEndTs);

  pool.shareSeconds.push({ tranche, perAccount: epochSS, total: epochTotalSS });
}

export function aggregateEpoch(snapshot: EpochSnapshot): AggregateResult {
  const pools = new Map<Hex, PoolAggregate>();
  const ensure = (rawPoolId: Hex): PoolAggregate => {
    const poolId = rawPoolId.toLowerCase() as Hex;
    let p = pools.get(poolId);
    if (!p) {
      p = {
        poolId,
        regime: null,
        feesPaidE6: 0n,
        feesEarnedE6: 0n,
        revenueE6: 0n,
        traderWeightE6: new Map(),
        lpWeightE6: new Map(),
        shareSeconds: [],
        unattributedFeesE6: 0n,
      };
      pools.set(poolId, p);
    }
    return p;
  };

  // ensure every priced pool exists (so 0-activity pools are represented)
  for (const pp of snapshot.pools) ensure(pp.poolId);

  // 1) fees paid per trader
  for (const s of snapshot.swaps) {
    const p = ensure(s.poolId);
    if (p.regime === null) p.regime = s.regime;
    const feeE6 = swapFeeE6(s, pricingFor(snapshot, s.poolId));
    p.feesPaidE6 += feeE6;
    addTo(p.traderWeightE6, s.trader, feeE6);
  }

  // 2) revenue (perf fees) per pool
  for (const f of snapshot.feesCollected) {
    const p = ensure(f.poolId);
    const pricing = pricingFor(snapshot, f.poolId);
    p.revenueE6 +=
      valueE6(f.perfFee0, pricing.price0E6, pricing.token0.decimals) +
      valueE6(f.perfFee1, pricing.price1E6, pricing.token1.decimals);
  }

  // 3) fees earned per LP: share-seconds attribution PER (pool, tranche) — INV-15.
  const key = (poolId: Hex, tranche: number) => `${poolId.toLowerCase()}:${tranche}`;
  const depsBy = groupBy(snapshot.deposits, (d) => key(d.poolId, d.tranche));
  const wdsBy = groupBy(snapshot.withdraws, (w) => key(w.poolId, w.tranche));
  const feesBy = groupBy(snapshot.feesCollected, (f) => key(f.poolId, f.tranche));
  const inRange = (b: bigint) => b >= snapshot.fromBlock && b <= snapshot.toBlock;
  const xfersBy = groupBy(
    (snapshot.shareTransfers ?? []).filter((x) => inRange(x.blockNumber)),
    (x) => key(x.poolId, x.tranche),
  );
  const openBy = new Map<string, { account: Address; shares: bigint }[]>();
  for (const o of snapshot.openingShares ?? []) openBy.set(key(o.poolId, o.tranche ?? 0), o.balances);

  // deterministic tranche set per pool = union of tranches seen in any stream source
  const tranchesByPool = new Map<Hex, Set<number>>();
  const noteTranche = (poolId: Hex, tranche: number) => {
    const pid = poolId.toLowerCase() as Hex;
    const s = tranchesByPool.get(pid) ?? new Set<number>();
    s.add(tranche);
    tranchesByPool.set(pid, s);
  };
  for (const d of snapshot.deposits) noteTranche(d.poolId, d.tranche);
  for (const w of snapshot.withdraws) noteTranche(w.poolId, w.tranche);
  for (const f of snapshot.feesCollected) noteTranche(f.poolId, f.tranche);
  for (const x of snapshot.shareTransfers ?? []) noteTranche(x.poolId, x.tranche);
  for (const o of snapshot.openingShares ?? []) noteTranche(o.poolId, o.tranche ?? 0);

  for (const p of pools.values()) {
    const tranches = [...(tranchesByPool.get(p.poolId) ?? new Set<number>())].sort((a, b) => a - b);
    for (const tr of tranches) {
      const k = key(p.poolId, tr);
      attributeTranche(
        p,
        pricingFor(snapshot, p.poolId),
        tr,
        openBy.get(k) ?? [],
        depsBy.get(k) ?? [],
        wdsBy.get(k) ?? [],
        feesBy.get(k) ?? [],
        xfersBy.get(k) ?? [],
        snapshot.epochEndTs,
      );
    }
  }

  let revenueE6 = 0n;
  let totalFeesPaidE6 = 0n;
  let totalFeesEarnedE6 = 0n;
  for (const p of pools.values()) {
    revenueE6 += p.revenueE6;
    totalFeesPaidE6 += p.feesPaidE6;
    totalFeesEarnedE6 += p.feesEarnedE6;
  }
  return { pools, revenueE6, totalFeesPaidE6, totalFeesEarnedE6 };
}

function groupBy<T>(arr: T[], keyOf: (t: T) => string): Map<string, T[]> {
  const m = new Map<string, T[]>();
  for (const item of arr) {
    const k = keyOf(item);
    const list = m.get(k) ?? [];
    list.push(item);
    m.set(k, list);
  }
  return m;
}
