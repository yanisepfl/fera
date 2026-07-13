// Funding-cluster self-match exclusion (INV-13 / MECHANISM_SPEC §4.7 / MASTER_SPEC v0.6 §9).
// CONSENSUS-CRITICAL: this file is part of the reproducibility bundle's scriptVersionHash.
// The algorithm is specified precisely in pipeline/README.md — keep them in lockstep.
//
// Summary (see README for the normative statement):
//   cluster  = connected components of (first-funder graph, depth ≤ 2) ∪ (vault share
//              transfers), computed deterministically from the frozen epoch snapshot.
//   LP leaf  : the portion of an account's fees-earned weight attributable to swaps from
//              wallets in the SAME cluster is excluded — zero emissions on that flow.
//   TR leaf  : a trader's fees-paid weight is zeroed in a pool when the trader's cluster
//              holds ≥ SELF_MATCH_MIN_CLUSTER_SHARE_BPS of that pool's vault shares
//              (time-weighted share-seconds over the epoch, max across tranches).
//   Stance   : DEFAULT-ALLOW — routers/solvers/settlement contracts cannot be clustered;
//              their flow counts as external (documented evasion friction, not a bound).

import {
  SELF_MATCH_EXCLUSION,
  SELF_MATCH_MIN_CLUSTER_SHARE_BPS,
  BPS,
} from "./config";
import type { AggregateResult } from "./aggregate";
import type {
  Address,
  BoostExclusionE6,
  ClusterInfo,
  EpochSnapshot,
  Hex,
} from "./types";

// ---------------------------------------------------------------------------
// Union-find with deterministic canonical representatives.
// ---------------------------------------------------------------------------

class UnionFind {
  private parent = new Map<Address, Address>();

  find(a: Address): Address {
    let root = a;
    while (this.parent.get(root) !== undefined && this.parent.get(root) !== root) {
      root = this.parent.get(root)!;
    }
    if (this.parent.get(root) === undefined) this.parent.set(root, root);
    // path compression (order-independent: final roots are canonicalized below)
    let cur = a;
    while (cur !== root) {
      const next = this.parent.get(cur)!;
      this.parent.set(cur, root);
      cur = next;
    }
    return root;
  }

  union(a: Address, b: Address): void {
    const ra = this.find(a);
    const rb = this.find(b);
    if (ra === rb) return;
    // deterministic: smaller address becomes the root
    if (ra < rb) this.parent.set(rb, ra);
    else this.parent.set(ra, rb);
  }

  members(): Map<Address, Address[]> {
    const byRoot = new Map<Address, Address[]>();
    for (const a of [...this.parent.keys()].sort()) {
      const r = this.find(a);
      const list = byRoot.get(r) ?? [];
      list.push(a);
      byRoot.set(r, list);
    }
    return byRoot;
  }
}

export interface ClusterMap {
  /** canonical representative (lexicographically smallest member) for every clustered wallet */
  repOf: (a: Address) => Address;
  /** clusters with ≥ 2 members, sorted by rep — published in the bundle */
  clusters: ClusterInfo[];
  /** true when the address is a router/solver/settlement contract (never clustered) */
  isUnclusterable: (a: Address) => boolean;
}

const lc = (a: Address) => a.toLowerCase() as Address;

/**
 * Build the depth-2 wallet-funding clusters from the frozen snapshot.
 * Deterministic: edges are normalized to lowercase, sorted, and unioned with a
 * smallest-address-wins rule; the representative of a component is its smallest member.
 */
export function buildClusters(snapshot: EpochSnapshot): ClusterMap {
  const unclusterable = new Set<Address>((snapshot.unclusterableAddresses ?? []).map(lc));
  const isUnclusterable = (a: Address) => unclusterable.has(lc(a));

  const uf = new UnionFind();

  // first-funder parent pointers (child -> funder), lowercased, unclusterables skipped
  const funderOf = new Map<Address, Address>();
  for (const e of snapshot.fundingEdges ?? []) {
    const child = lc(e.child);
    const funder = lc(e.funder);
    if (child === funder) continue;
    if (isUnclusterable(child) || isUnclusterable(funder)) continue;
    // one first-funder per child; if the snapshot carries duplicates keep the smallest
    // funder (deterministic; duplicate edges indicate an upstream snapshot bug)
    const prev = funderOf.get(child);
    if (prev === undefined || funder < prev) funderOf.set(child, funder);
  }

  // depth-1 edge: child ↔ firstFunder(child); depth-2 edge: child ↔ firstFunder(firstFunder(child))
  // (SELF_MATCH_FUND_DEPTH = 2 — PARAMS.md). Sorted iteration for determinism.
  for (const child of [...funderOf.keys()].sort()) {
    const f1 = funderOf.get(child)!;
    uf.union(child, f1);
    const f2 = funderOf.get(f1);
    if (f2 !== undefined && f2 !== child) uf.union(child, f2);
  }

  // vault share transfer edges: from ↔ to (any pool/tranche, since genesis), skipping mints,
  // burns (zero address) and unclusterable endpoints.
  const ZERO = "0x0000000000000000000000000000000000000000" as Address;
  const xferEdges: { a: Address; b: Address }[] = [];
  for (const x of snapshot.shareTransfers ?? []) {
    const from = lc(x.from);
    const to = lc(x.to);
    if (from === to || from === ZERO || to === ZERO) continue;
    if (isUnclusterable(from) || isUnclusterable(to)) continue;
    xferEdges.push(from < to ? { a: from, b: to } : { a: to, b: from });
  }
  xferEdges.sort((x, y) => (x.a === y.a ? (x.b < y.b ? -1 : 1) : x.a < y.a ? -1 : 1));
  for (const e of xferEdges) uf.union(e.a, e.b);

  const byRoot = uf.members();
  const clusters: ClusterInfo[] = [];
  const repMap = new Map<Address, Address>();
  for (const [, members] of byRoot) {
    const sorted = [...members].sort();
    const rep = sorted[0]!;
    for (const m of sorted) repMap.set(m, rep);
    if (sorted.length >= 2) clusters.push({ rep, members: sorted });
  }
  clusters.sort((a, b) => (a.rep < b.rep ? -1 : 1));

  return {
    repOf: (a: Address) => repMap.get(lc(a)) ?? lc(a),
    clusters,
    isUnclusterable,
  };
}

/**
 * Derive the per-(pool, account) self-match exclusions from the epoch aggregate + clusters.
 * MECHANISM_SPEC §4.7 / MASTER_SPEC §9: caught ⇒ ZERO emissions on that flow.
 *
 *  LP leaf   — excludedLpWeight(a, p) = lpWeight(a, p) × clusterFeesPaid(cluster(a), p)
 *                                       / totalFeesPaid(p)          (floor division)
 *              i.e. the fraction of the pool's swap-fee flow that came from a's own cluster
 *              is removed from a's fees-earned weight. Epoch-granular attribution (see
 *              README §"LP-leaf exclusion" for why this is the deterministic realization).
 *  Trader leaf — traderWeight(t, p) is zeroed entirely when cluster(t)'s time-weighted
 *              share-seconds fraction ≥ SELF_MATCH_MIN_CLUSTER_SHARE_BPS in ANY tranche of p.
 *  Unclusterable traders (routers/solvers) are never excluded — DEFAULT-ALLOW.
 */
export function computeSelfMatchExclusions(
  agg: AggregateResult,
  clusters: ClusterMap,
  _snapshot: EpochSnapshot,
): BoostExclusionE6[] {
  if (!SELF_MATCH_EXCLUSION) return [];
  const out: BoostExclusionE6[] = [];

  for (const poolId of [...agg.pools.keys()].sort()) {
    const pool = agg.pools.get(poolId)!;

    // fees paid per cluster in this pool (unclusterable traders count as external — their
    // cluster is themselves, but they can never match an LP because repOf(router)=router and
    // LPs are EOAs; belt-and-braces: skip them explicitly)
    const clusterFeesE6 = new Map<Address, bigint>();
    for (const [trader, feeE6] of pool.traderWeightE6) {
      if (clusters.isUnclusterable(trader)) continue;
      const rep = clusters.repOf(trader);
      clusterFeesE6.set(rep, (clusterFeesE6.get(rep) ?? 0n) + feeE6);
    }

    // cluster share-seconds fraction per tranche (bps), max across tranches
    const clusterShareBps = new Map<Address, bigint>();
    for (const tr of pool.shareSeconds) {
      if (tr.total <= 0n) continue;
      const perCluster = new Map<Address, bigint>();
      for (const [acct, ss] of tr.perAccount) {
        const rep = clusters.repOf(acct);
        perCluster.set(rep, (perCluster.get(rep) ?? 0n) + ss);
      }
      for (const [rep, ss] of perCluster) {
        const bps = (ss * BPS) / tr.total;
        const prev = clusterShareBps.get(rep) ?? 0n;
        if (bps > prev) clusterShareBps.set(rep, bps);
      }
    }

    // LP-leaf exclusion
    const lp: { account: Address; weightE6: bigint }[] = [];
    if (pool.feesPaidE6 > 0n) {
      for (const account of [...pool.lpWeightE6.keys()].sort()) {
        const w = pool.lpWeightE6.get(account)!;
        const rep = clusters.repOf(account);
        const selfFees = clusterFeesE6.get(rep) ?? 0n;
        if (selfFees <= 0n) continue;
        const excluded = (w * selfFees) / pool.feesPaidE6; // floor
        if (excluded > 0n) lp.push({ account, weightE6: excluded });
      }
    }

    // Trader-leaf exclusion (zeroed when the cluster holds ≥ threshold of pool shares)
    const trader: { account: Address; weightE6: bigint }[] = [];
    for (const account of [...pool.traderWeightE6.keys()].sort()) {
      if (clusters.isUnclusterable(account)) continue;
      const rep = clusters.repOf(account);
      const shareBps = clusterShareBps.get(rep) ?? 0n;
      if (shareBps >= SELF_MATCH_MIN_CLUSTER_SHARE_BPS) {
        trader.push({ account, weightE6: pool.traderWeightE6.get(account)! });
      }
    }

    if (lp.length > 0 || trader.length > 0) out.push({ poolId, lp, trader });
  }
  return out;
}

/**
 * Cluster-collapsed unique-trader count per pool (PT-9): raw addresses never raise a pool's
 * quality score — each cluster counts once. Unclusterable (router) traders count as ONE
 * identity each; routers hide many users, so this UNDER-counts diversity → lower divMult →
 * under-emission: the safe direction (documented in README).
 */
export function uniqueClusterTraders(
  traderWeightE6: Map<Address, bigint>,
  clusters: ClusterMap,
): number {
  const seen = new Set<Address>();
  for (const t of traderWeightE6.keys()) seen.add(clusters.repOf(t));
  return seen.size;
}
