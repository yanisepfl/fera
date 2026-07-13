// Core emissions computation — MASTER_SPEC v0.6 §9 with the D-M8 NORMATIVE ORDERING
// (MECHANISM_SPEC §4.4 "pipeline order of operations", INV-13 structural fix). CONSENSUS-
// CRITICAL: versioned via scriptVersionHash; never hotfixed after posting.
//
// ┌─ D-M8 order of operations (normative — binds this file) ────────────────────────────────┐
// │ 1. E        = min( capEpoch, β·ΣR_p/feraTwap )        // fixed epoch envelope (INV-7)   │
// │ 2. E_p      = min( capShare_p, β·R_p/feraTwap )       // per-pool revenue lock — FINAL, │
// │              capShare_p = capEpoch·Q_p/ΣQ,            // holds AFTER boost weighting    │
// │              Q_p = R_p·divMult_p (PT-9 cluster-collapsed diversity)         (PT-5)      │
// │ 3. split WITHIN the pool: 5% traders / 85% LPs / 10% treasury (Decision-A″ frozen, F-10)  │
// │ 4. LP leaf  : weight_a = shareTimeWeightedFeesEarned_a(NON-SELF-CLUSTERED flow, §4.7)   │
// │               × boost_a, normalized over the SAME pool's LP claimants ONLY              │
// │    TR leaf  : pro-rata fees paid within the pool (no boost — Decision B),               │
// │               cluster-share ≥5% traders zeroed (§4.7)                                   │
// └──────────────────────────────────────────────────────────────────────────────────────────┘
//
// Consequences (assert in the dry-run):
//  - Boost is redistributive WITHIN a pool's LP leaf: Σ_a lpAlloc_a == s_LP·E_p exactly, for
//    any boost vector ⇒ boost can NEVER import emissions across pools (kills PT-2 attack B;
//    at f=1 boost redistributes among the attacker alone — it does nothing).
//  - The per-pool revenue lock is FINAL: a pool bound below its cap share leaves FERA
//    UN-emitted (it stays in the 90% bucket) — never redistributed to other pools.
//  - emitted = Σ_p E_p ≤ E = min(cap, β·rev): INV-7 holds by construction, after boost.
//  - Self-matched flow earns ZERO emissions (weight excluded — base AND boost; §9 "caught ⇒
//    zero emissions on that flow").
//
// Treasury's 10% is funded DIRECTLY by the controller and is NOT a Merkle leaf (leaf kinds
// are only {0 trader, 1 lp}). Allocation dust + zero-weight residues also fold to treasury.

import { usdE6ToFeraWei } from "../src/lib/prices";
import { aggregateEpoch } from "./aggregate";
import { allocate } from "./alloc";
import { buildClusters, computeSelfMatchExclusions, uniqueClusterTraders } from "./cluster";
import { computeLeaf, buildTree, getProof } from "./merkle";
import {
  BETA_BPS,
  BPS,
  SPLIT_TRADER_BPS,
  SPLIT_LP_BPS,
  EMITTABLE_SUPPLY_FERA_WEI,
  CAP_HORIZON_EPOCHS,
  CAP_LOGISTIC_K_E6,
  CAP_LOGISTIC_MIDPOINT_EPOCH,
  INSTANT_EXIT_KEEP_BPS,
  POOL_DIVERSITY_D0,
  POOL_DIVERSITY_MIN_BPS,
} from "./config";
import {
  KIND_TRADER,
  KIND_LP,
  type EpochSnapshot,
  type EpochResult,
  type LeafEntry,
  type PoolBreakdown,
  type Address,
  type Hex,
  type Kind,
} from "./types";

const WAD = 10n ** 18n;

/**
 * Reference logistic cap(epochId) → FERA wei. NON-CONSENSUS: production reads the authoritative
 * cap from EmissionsController on-chain (which enforces INV-7 with integer math). This helper
 * uses float and exists only to synthesise a snapshot when no on-chain value is available.
 * TODO(spec-freeze): must match the on-chain PRB-Math formula bit-for-bit before mainnet.
 */
export function logisticCap(epochId: bigint): bigint {
  const e = Number(epochId);
  const k = Number(CAP_LOGISTIC_K_E6) / 1e6;
  const mid = Number(CAP_LOGISTIC_MIDPOINT_EPOCH);
  const L = (x: number) => 1 / (1 + Math.exp(-k * (x - mid)));
  const denom = L(Number(CAP_HORIZON_EPOCHS)) - L(0);
  const frac = (L(e + 1) - L(e)) / denom; // this epoch's slice of the S-curve
  const cap = (Number(EMITTABLE_SUPPLY_FERA_WEI) * Math.max(frac, 0)) / 1;
  return BigInt(Math.floor(cap));
}

export function computeEpoch(snapshot: EpochSnapshot): EpochResult {
  const agg = aggregateEpoch(snapshot);

  // ── funding-cluster self-match exclusion (§4.7) — deterministic from the snapshot ──
  const clusterMap = buildClusters(snapshot);
  const exclusions = computeSelfMatchExclusions(agg, clusterMap, snapshot);
  const exclLpByPool = new Map<Hex, Map<Address, bigint>>();
  const exclTraderByPool = new Map<Hex, Map<Address, bigint>>();
  for (const e of exclusions) {
    exclLpByPool.set(e.poolId, new Map(e.lp.map((x) => [x.account, x.weightE6])));
    exclTraderByPool.set(e.poolId, new Map(e.trader.map((x) => [x.account, x.weightE6])));
  }

  // ── D-M8 step 1: fixed epoch envelope E = min(cap, β·rev/twap) ──
  const revenueValueE6 = agg.revenueE6;
  const revenueValuedInFeraWei =
    snapshot.feraTwapE6 > 0n ? usdE6ToFeraWei(revenueValueE6, snapshot.feraTwapE6) : 0n;
  const revenueBoundFeraWei = (revenueValuedInFeraWei * BETA_BPS) / BPS;
  const capFeraWei = snapshot.capFeraWei;
  const epochTotalFeraWei =
    capFeraWei < revenueBoundFeraWei ? capFeraWei : revenueBoundFeraWei;

  // ── D-M8 step 2: per-pool allocation + FINAL per-pool locks ──
  // Q_p = R_p × divMult_p; divMult from snapshot override else cluster-collapsed diversity.
  const poolIds = [...agg.pools.keys()].sort();
  const divMultBpsOf = new Map<Hex, bigint>();
  for (const pid of poolIds) {
    const override = snapshot.qualityScoreBps?.[pid];
    if (override !== undefined) {
      divMultBpsOf.set(pid, BigInt(override));
    } else {
      const uniq = BigInt(uniqueClusterTraders(agg.pools.get(pid)!.traderWeightE6, clusterMap));
      let bps = (uniq * BPS) / POOL_DIVERSITY_D0;
      if (bps < POOL_DIVERSITY_MIN_BPS) bps = POOL_DIVERSITY_MIN_BPS;
      if (bps > BPS) bps = BPS;
      divMultBpsOf.set(pid, bps);
    }
  }
  const qualityWeights = poolIds.map((pid) => ({
    key: pid,
    keyStr: pid,
    weight: (agg.pools.get(pid)!.revenueE6 * divMultBpsOf.get(pid)!) / BPS, // Q_p (E6)
  }));
  // capShare_p = capEpoch · Q_p / ΣQ  (Hamilton exact; unallocatable when ΣQ = 0)
  const capShares = allocate(capFeraWei, qualityWeights);

  const boostX18 = (acct: Address) => {
    const b = snapshot.boostX18[acct] ?? WAD;
    if (b < WAD) return WAD; // clamp to [1x, 2x] — PARAMS.md#BOOST_MAX
    if (b > 2n * WAD) return 2n * WAD;
    return b;
  };

  const breakdowns: PoolBreakdown[] = [];
  const traderAmt = new Map<Address, bigint>();
  const lpAmt = new Map<Address, bigint>();
  let emittedFeraWei = 0n;
  let traderTotal = 0n;
  let lpTotal = 0n;
  let treasuryTotal = 0n;

  for (const pid of poolIds) {
    const p = agg.pools.get(pid)!;
    const capShare = capShares.alloc.get(pid) ?? 0n;
    const revenueLock =
      snapshot.feraTwapE6 > 0n
        ? (usdE6ToFeraWei(p.revenueE6, snapshot.feraTwapE6) * BETA_BPS) / BPS
        : 0n;
    // E_p = min(capShare_p, β·R_p/twap [, optional extra absolute cap — can only lower])
    let poolEmission = capShare < revenueLock ? capShare : revenueLock;
    const extraCap = snapshot.poolCapFeraWei?.[pid];
    if (extraCap !== undefined && extraCap < poolEmission) poolEmission = extraCap;
    // NOTE: the lock is FINAL. Any gap (capShare − E_p) is NOT emitted and NOT redistributed.

    // ── D-M8 step 3: split WITHIN the pool (85/5/10) ──
    const traderLeg = (poolEmission * SPLIT_TRADER_BPS) / BPS;
    const lpLeg = (poolEmission * SPLIT_LP_BPS) / BPS;
    let treasuryLeg = poolEmission - traderLeg - lpLeg; // 10% + integer dust

    // ── D-M8 step 4: within-pool leaves ──
    // Trader leaf: pro-rata fees paid, cluster-share ≥5% traders zeroed, NO boost.
    const exclTrader = exclTraderByPool.get(pid);
    const traderInputs = [...p.traderWeightE6.entries()]
      .map(([a, w]) => {
        const excluded = exclTrader?.get(a) ?? 0n;
        const eligible = w > excluded ? w - excluded : 0n;
        return { key: a, keyStr: a, weight: eligible };
      })
      .filter((x) => x.weight > 0n);
    const traderAlloc = allocate(traderLeg, traderInputs);

    // LP leaf: (fees-earned weight − self-clustered flow) × boost, normalized WITHIN the pool.
    // The exclusion removes BASE weight (zero emissions on that flow), not just the premium.
    const exclLp = exclLpByPool.get(pid);
    const lpInputs = [...p.lpWeightE6.entries()]
      .map(([a, w]) => {
        const excluded = exclLp?.get(a) ?? 0n;
        const eligible = w > excluded ? w - excluded : 0n;
        const weighted = (eligible * boostX18(a)) / WAD; // boost on ELIGIBLE weight only
        return { key: a, keyStr: a, weight: weighted };
      })
      .filter((x) => x.weight > 0n);
    const lpAlloc = allocate(lpLeg, lpInputs);

    // zero-weight residues fold to treasury (pool had emissions but no eligible claimants)
    treasuryLeg += traderAlloc.unallocated + lpAlloc.unallocated;
    const traderAllocated = traderLeg - traderAlloc.unallocated;
    const lpAllocated = lpLeg - lpAlloc.unallocated;

    for (const [a, v] of traderAlloc.alloc) if (v > 0n) traderAmt.set(a, (traderAmt.get(a) ?? 0n) + v);
    for (const [a, v] of lpAlloc.alloc) if (v > 0n) lpAmt.set(a, (lpAmt.get(a) ?? 0n) + v);

    emittedFeraWei += poolEmission;
    traderTotal += traderAllocated;
    lpTotal += lpAllocated;
    treasuryTotal += treasuryLeg;

    let excludedLpWeightE6 = 0n;
    for (const v of exclLp?.values() ?? []) excludedLpWeightE6 += v;
    let excludedTraderWeightE6 = 0n;
    for (const v of exclTrader?.values() ?? []) excludedTraderWeightE6 += v;

    breakdowns.push({
      poolId: pid,
      regime: p.regime,
      feesPaidE6: p.feesPaidE6,
      feesEarnedE6: p.feesEarnedE6,
      revenueE6: p.revenueE6,
      divMultBps: Number(divMultBpsOf.get(pid)!),
      capShareFeraWei: capShare,
      revenueLockFeraWei: revenueLock,
      poolEmissionFeraWei: poolEmission,
      traderEmissionFeraWei: traderAllocated,
      lpEmissionFeraWei: lpAllocated,
      treasuryFeraWei: treasuryLeg,
      excludedLpWeightE6,
      excludedTraderWeightE6,
    });
  }

  // ── build leaves (kinds 0 trader / 1 lp, amount > 0) ──
  const leaves: LeafEntry[] = [];
  const pushLeaf = (account: Address, kind: Kind, amount: bigint) => {
    if (amount <= 0n) return;
    leaves.push({ account, kind, amount, leaf: computeLeaf(snapshot.epochId, account, kind, amount) });
  };
  for (const [a, v] of traderAmt) pushLeaf(a, KIND_TRADER, v);
  for (const [a, v] of lpAmt) pushLeaf(a, KIND_LP, v);
  // deterministic order for the bundle (does not affect root; tree re-sorts by hash)
  leaves.sort((x, y) =>
    x.account === y.account ? x.kind - y.kind : x.account < y.account ? -1 : 1,
  );

  const totalEsFeraWei = leaves.reduce((s, l) => s + l.amount, 0n);
  const tree = leaves.length > 0 ? buildTree(leaves.map((l) => l.leaf)) : null;

  // ── wash-farm guardrail (non-consensus diagnostic) ──
  // rebate value after immediate 50% exit must stay below fees paid, per pool-agnostic trader
  const globalFeesPaid = new Map<Address, bigint>();
  for (const p of agg.pools.values())
    for (const [a, v] of p.traderWeightE6)
      globalFeesPaid.set(a, (globalFeesPaid.get(a) ?? 0n) + v);
  const washFarmFlags: EpochResult["washFarmFlags"] = [];
  for (const [a, feraWei] of traderAmt) {
    // esFERA -> FERA at 50% instant exit, valued back to USD E6
    const feraOut = (feraWei * INSTANT_EXIT_KEEP_BPS) / BPS;
    const rebateValueE6 = (feraOut * snapshot.feraTwapE6) / WAD;
    const feesPaidE6 = globalFeesPaid.get(a) ?? 0n;
    if (rebateValueE6 > feesPaidE6)
      washFarmFlags.push({ account: a, feesPaidE6, rebateValueE6 });
  }

  return {
    epochId: snapshot.epochId,
    capFeraWei,
    revenueValuedInFeraWei, // F-11: raw revenue valued in FERA (pre-β) — passed to finalizeEpoch
    revenueBoundFeraWei,
    epochTotalFeraWei,
    emittedFeraWei,
    feraTwapE6: snapshot.feraTwapE6,
    traderPoolFeraWei: traderTotal,
    lpPoolFeraWei: lpTotal,
    treasuryFeraWei: treasuryTotal,
    revenueValueE6,
    totalFeesPaidE6: agg.totalFeesPaidE6,
    totalFeesEarnedE6: agg.totalFeesEarnedE6,
    leaves,
    merkleRoot: tree ? tree.root : (("0x" + "00".repeat(32)) as Hex),
    totalEsFeraWei,
    pools: breakdowns,
    clusters: clusterMap.clusters,
    boostExclusionE6: exclusions,
    washFarmFlags,
  };
}

/** Convenience: proof for a specific (account, kind) leaf against the epoch tree. */
export function proofFor(result: EpochResult, account: Address, kind: Kind): {
  amount: bigint;
  proof: Hex[];
} | null {
  const entry = result.leaves.find(
    (l) => l.account.toLowerCase() === account.toLowerCase() && l.kind === kind,
  );
  if (!entry) return null;
  const tree = buildTree(result.leaves.map((l) => l.leaf));
  return { amount: entry.amount, proof: getProof(tree, entry.leaf) };
}
