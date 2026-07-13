// Emissions pipeline dry-run (MASTER_SPEC v0.6 §9, DoD §14: "3 dry-run epochs before mainnet").
// Runs the WHOLE pipeline (D-M8 ordering + 85/5/10 split + funding-cluster exclusion + PT-8 TWAP)
// over MOCKED events, prints the root + reproducibility bundle, and asserts the consensus
// invariants — including two COUNTERFACTUAL runs (no-boost, no-cluster) that pin down exactly
// what boost and the self-match exclusion may and may not change. Exit code != 0 on any failure.
//
//   npm run pipeline:dryrun
//
import { computeEpoch, proofFor } from "./emissions";
import { buildTree, getProof, verify } from "./merkle";
import { buildBundle, stableStringify, writeBundle, computeScriptVersionHash } from "./bundle";
import { feraTwapE6 } from "./twap";
import { BPS, SPLIT_TRADER_BPS, SPLIT_LP_BPS, SPLIT_TREASURY_BPS } from "./config";
import { KIND_TRADER, KIND_LP, type EpochResult, type Address } from "./types";
import {
  mockEpochSnapshot,
  POOL_MEME,
  POOL_RWA,
  WHALE,
  WASH,
  WASH2,
  LP1,
  LP2,
  LP4,
  ROUTER,
  T1,
  T2,
} from "./mocks/events";

let failures = 0;
function check(name: string, cond: boolean, detail = "") {
  const ok = cond ? "PASS" : "FAIL";
  if (!cond) failures++;
  console.log(`  [${ok}] ${name}${detail ? ` — ${detail}` : ""}`);
}

function fmtFera(wei: bigint): string {
  const whole = wei / 10n ** 18n;
  const frac = (wei % 10n ** 18n).toString().padStart(18, "0").slice(0, 6);
  return `${whole}.${frac}`;
}
function fmtUsd(e6: bigint): string {
  return `$${(Number(e6) / 1e6).toFixed(4)}`;
}
const leafAmt = (r: EpochResult, account: Address, kind: 0 | 1): bigint =>
  r.leaves.find((l) => l.account.toLowerCase() === account.toLowerCase() && l.kind === kind)
    ?.amount ?? 0n;

function printResult(r: EpochResult) {
  console.log("\n=== HEADLINE (mirrors EpochFinalized §6) ===");
  console.log(`  epochId              ${r.epochId}`);
  console.log(`  feraTwap             ${fmtUsd(r.feraTwapE6)} / FERA`);
  console.log(`  revenue              ${fmtUsd(r.revenueValueE6)}`);
  console.log(`  cap                  ${fmtFera(r.capFeraWei)} FERA`);
  console.log(`  revenueBound (βR)    ${fmtFera(r.revenueBoundFeraWei)} FERA`);
  console.log(`  EPOCH TOTAL (min)    ${fmtFera(r.epochTotalFeraWei)} FERA   [D-M8 step 1]`);
  console.log(`  EMITTED (Σ E_p)      ${fmtFera(r.emittedFeraWei)} FERA   [≤ total; per-pool locks final]`);
  console.log(`    trader leaves  5%  ${fmtFera(r.traderPoolFeraWei)}`);
  console.log(`    lp leaves     85%  ${fmtFera(r.lpPoolFeraWei)}`);
  console.log(`    treasury      10%* ${fmtFera(r.treasuryFeraWei)}  (*+dust; funded directly)`);
  console.log(`  merkleRoot           ${r.merkleRoot}`);
  console.log(`  totalEsFera(leaves)  ${fmtFera(r.totalEsFeraWei)}`);

  console.log("\n=== PER-POOL BREAKDOWN (D-M8: E_p = min(capShare, β·R_p/twap)) ===");
  for (const p of r.pools) {
    console.log(
      `  ${p.poolId.slice(0, 10)}… regime=${p.regime} divMult=${p.divMultBps}bps ` +
        `rev=${fmtUsd(p.revenueE6)} capShare=${fmtFera(p.capShareFeraWei)} ` +
        `revLock=${fmtFera(p.revenueLockFeraWei)} E_p=${fmtFera(p.poolEmissionFeraWei)}`,
    );
    console.log(
      `      trader=${fmtFera(p.traderEmissionFeraWei)} lp=${fmtFera(p.lpEmissionFeraWei)} ` +
        `treasury=${fmtFera(p.treasuryFeraWei)} exclLpW=${fmtUsd(p.excludedLpWeightE6)} ` +
        `exclTrW=${fmtUsd(p.excludedTraderWeightE6)}`,
    );
  }

  console.log("\n=== FUNDING CLUSTERS (depth-2 + share transfers, §4.7) ===");
  for (const c of r.clusters) console.log(`  rep=${c.rep} members=[${c.members.join(", ")}]`);
  for (const e of r.boostExclusionE6) {
    console.log(`  exclusions ${e.poolId.slice(0, 10)}…`);
    for (const x of e.lp) console.log(`    lp     ${x.account} −${fmtUsd(x.weightE6)} weight`);
    for (const x of e.trader) console.log(`    trader ${x.account} −${fmtUsd(x.weightE6)} weight (zeroed)`);
  }

  console.log("\n=== MERKLE LEAVES (kind 0=trader 1=lp) ===");
  for (const l of r.leaves) {
    console.log(`  ${l.account} kind=${l.kind} amount=${fmtFera(l.amount)} leaf=${l.leaf.slice(0, 12)}…`);
  }

  if (r.washFarmFlags.length > 0) {
    console.log("\n=== WASH-FARM GUARDRAIL FLAGS (rebate>fees; investigate) ===");
    for (const f of r.washFarmFlags)
      console.log(`  ${f.account} feesPaid=${fmtUsd(f.feesPaidE6)} rebateValue=${fmtUsd(f.rebateValueE6)}`);
  } else {
    console.log("\n  wash-farm guardrail: no flags (rebate value < fees paid for all traders).");
  }
}

function main() {
  console.log("FERA emissions pipeline v3 — DRY RUN over mocked events (D-M8 + 85/5/10 + §4.7)");
  console.log(`script version hash: ${computeScriptVersionHash()}`);

  const snapshot = mockEpochSnapshot(0n);
  const r = computeEpoch(snapshot);
  printResult(r);

  console.log("\n=== INVARIANT SELF-CHECK — D-M8 ordering ===");
  // Step 1: fixed epoch envelope
  const expectedTotal = r.capFeraWei < r.revenueBoundFeraWei ? r.capFeraWei : r.revenueBoundFeraWei;
  check("epochTotal == min(cap, β×revenue)  [INV-7 / D-M8 step 1]", r.epochTotalFeraWei === expectedTotal);

  // Step 2: per-pool locks are FINAL and hold AFTER boost weighting
  let sumEp = 0n;
  let perPoolOk = true;
  let lockOk = true;
  let splitOk = true;
  for (const p of r.pools) {
    sumEp += p.poolEmissionFeraWei;
    // conservation within the pool: everything E_p is either a leaf or treasury
    if (p.traderEmissionFeraWei + p.lpEmissionFeraWei + p.treasuryFeraWei !== p.poolEmissionFeraWei)
      perPoolOk = false;
    // the double lock (post-boost totals may never exceed either bound)
    if (p.poolEmissionFeraWei > p.revenueLockFeraWei) lockOk = false;
    if (p.poolEmissionFeraWei > p.capShareFeraWei) lockOk = false;
    // 85/5/10 split of E_p (exact when the pool has eligible claimants — this mock does)
    if (p.traderEmissionFeraWei !== (p.poolEmissionFeraWei * SPLIT_TRADER_BPS) / BPS) splitOk = false;
    if (p.lpEmissionFeraWei !== (p.poolEmissionFeraWei * SPLIT_LP_BPS) / BPS) splitOk = false;
  }
  check("per-pool conservation: trader+lp+treasury == E_p (every pool)", perPoolOk);
  check("per-pool DOUBLE LOCK: E_p ≤ β·R_p/twap AND E_p ≤ capShare_p (post-boost)", lockOk);
  check("85/5/10 split WITHIN each pool (Decision-A″ frozen, F-10)", splitOk);
  check(
    "split constants are exactly 85/5/10 (LP/trader/treasury) and sum to 100% (F-10)",
    SPLIT_LP_BPS === 8500n && SPLIT_TRADER_BPS === 500n && SPLIT_TREASURY_BPS === 1000n &&
      SPLIT_LP_BPS + SPLIT_TRADER_BPS + SPLIT_TREASURY_BPS === BPS,
    `LP=${SPLIT_LP_BPS} TR=${SPLIT_TRADER_BPS} TREAS=${SPLIT_TREASURY_BPS}`,
  );
  check("emitted == Σ_p E_p", r.emittedFeraWei === sumEp);
  check("emitted ≤ epochTotal  [INV-7 after boost, PT-5]", r.emittedFeraWei <= r.epochTotalFeraWei);

  // RWA extra cap binds BELOW its revenue lock ⇒ the gap is UN-emitted, never redistributed
  const rwa = r.pools.find((p) => p.poolId === POOL_RWA)!;
  check(
    "per-pool lock is FINAL: RWA cap binds; gap stays un-emitted (emitted < epochTotal)",
    rwa.poolEmissionFeraWei === 10n * 10n ** 18n && r.emittedFeraWei < r.epochTotalFeraWei,
    `E_rwa=${fmtFera(rwa.poolEmissionFeraWei)}, gap=${fmtFera(r.epochTotalFeraWei - r.emittedFeraWei)}`,
  );

  // Global conservation: every emitted wei is a leaf or treasury
  const sumTrader = r.leaves.filter((l) => l.kind === KIND_TRADER).reduce((s, l) => s + l.amount, 0n);
  const sumLp = r.leaves.filter((l) => l.kind === KIND_LP).reduce((s, l) => s + l.amount, 0n);
  check(
    "conservation: traderLeaves + lpLeaves + treasury == emitted",
    sumTrader + sumLp + r.treasuryFeraWei === r.emittedFeraWei,
    `${fmtFera(sumTrader + sumLp + r.treasuryFeraWei)} vs ${fmtFera(r.emittedFeraWei)}`,
  );
  check("sum(leaf amounts) == totalEsFera (Distributor funding)", r.leaves.reduce((s, l) => s + l.amount, 0n) === r.totalEsFeraWei);

  console.log("\n=== INVARIANT SELF-CHECK — boost (Decision B + within-pool normalization) ===");
  // Counterfactual 1: NO BOOST. Trader leaves must be byte-identical (boost never touches the
  // trader leaf) and per-pool LP totals must be identical (boost is redistributive WITHIN a
  // pool — it can never import emissions across pools or change any pool's total).
  const rNoBoost = computeEpoch({ ...snapshot, boostX18: {} });
  const traderLeavesEq =
    JSON.stringify(r.leaves.filter((l) => l.kind === KIND_TRADER).map((l) => [l.account, l.amount.toString()])) ===
    JSON.stringify(rNoBoost.leaves.filter((l) => l.kind === KIND_TRADER).map((l) => [l.account, l.amount.toString()]));
  check("trader leaves byte-identical with boost removed (Decision B: no boost on rebate)", traderLeavesEq);
  let poolTotalsEq = true;
  for (const p of r.pools) {
    const q = rNoBoost.pools.find((x) => x.poolId === p.poolId)!;
    if (p.lpEmissionFeraWei !== q.lpEmissionFeraWei) poolTotalsEq = false;
    if (p.poolEmissionFeraWei !== q.poolEmissionFeraWei) poolTotalsEq = false;
  }
  check("per-pool LP totals identical with boost removed (boost never imports cross-pool)", poolTotalsEq);
  check("emitted identical with boost removed (boost reweights, never mints — PT-5)", r.emittedFeraWei === rNoBoost.emittedFeraWei);
  check(
    "boost redistributes toward the max-boosted staker WITHIN the pool (WHALE 2x)",
    leafAmt(r, WHALE, KIND_LP) > leafAmt(rNoBoost, WHALE, KIND_LP),
    `${fmtFera(leafAmt(rNoBoost, WHALE, KIND_LP))} → ${fmtFera(leafAmt(r, WHALE, KIND_LP))}`,
  );

  console.log("\n=== INVARIANT SELF-CHECK — funding-cluster self-match exclusion (§4.7) ===");
  // cluster construction: depth-2 {WHALE, WASH, WASH2}; share-transfer edge {LP1, LP4}
  // NOTE: the component also (correctly) contains WHALE's own first funder (CEX3) — funding
  // ancestry chains through connected components by design (README §4.1).
  const washCluster = r.clusters.find((c) => c.members.includes(WASH));
  check(
    "depth-2 funding cluster built: WHALE, WASH, WASH2 in one component (WASH2 via funder-of-funder)",
    !!washCluster && washCluster.members.includes(WHALE) && washCluster.members.includes(WASH2),
  );
  const lpCluster = r.clusters.find((c) => c.members.includes(LP4));
  check("share-transfer cluster built: {LP1, LP4}", !!lpCluster && lpCluster.members.includes(LP1) && lpCluster.members.length === 2);

  // trader leaf: WASH + WASH2 zeroed (their cluster holds 60% ≥ 5% of MEME vault shares)
  check("self-dealer wash flow: WASH trader leaf ZEROED (cluster holds ≥5% of shares)", leafAmt(r, WASH, KIND_TRADER) === 0n);
  check("self-dealer wash flow: WASH2 (depth-2) trader leaf ZEROED", leafAmt(r, WASH2, KIND_TRADER) === 0n);
  check("honest traders keep trader leaves (T1, T2)", leafAmt(r, T1, KIND_TRADER) > 0n && leafAmt(r, T2, KIND_TRADER) > 0n);
  check("router flow counts as external (DEFAULT-ALLOW): ROUTER keeps its trader leaf", leafAmt(r, ROUTER, KIND_TRADER) > 0n);

  // LP leaf: WHALE's weight from same-cluster flow excluded — zero emissions on that flow.
  // Counterfactual 2: same epoch with NO funding edges ⇒ WHALE unclustered ⇒ no exclusion.
  const rNoCluster = computeEpoch({ ...snapshot, fundingEdges: [] });
  const memeExcl = r.boostExclusionE6.find((e) => e.poolId === POOL_MEME);
  const whaleExcl = memeExcl?.lp.find((x) => x.account === WHALE);
  check("WHALE LP weight partially excluded (cluster fees $10 of $25 pool fees ⇒ 40%)", !!whaleExcl && whaleExcl.weightE6 > 0n);
  check(
    "excluded self-dealer captures STRICTLY LESS than the unexcluded counterfactual",
    leafAmt(r, WHALE, KIND_LP) < leafAmt(rNoCluster, WHALE, KIND_LP),
    `${fmtFera(leafAmt(r, WHALE, KIND_LP))} < ${fmtFera(leafAmt(rNoCluster, WHALE, KIND_LP))}`,
  );
  check(
    "honest LPs gain what the self-dealer loses (within-pool renormalization)",
    leafAmt(r, LP1, KIND_LP) > leafAmt(rNoCluster, LP1, KIND_LP) && leafAmt(r, LP2, KIND_LP) > leafAmt(rNoCluster, LP2, KIND_LP),
  );
  check("honest LPs untouched by the exclusion list (no false positives: LP1/LP2/LP4 not excluded)",
    !memeExcl?.lp.some((x) => x.account === LP1 || x.account === LP2 || x.account === LP4));
  check("share-transfer recipient LP4 earns LP emissions (transfer moved attribution)", leafAmt(r, LP4, KIND_LP) > 0n);

  console.log("\n=== INVARIANT SELF-CHECK — merkle + determinism + reproducibility ===");
  const tree = buildTree(r.leaves.map((l) => l.leaf));
  let allVerify = tree.root === r.merkleRoot;
  for (const l of r.leaves) allVerify &&= verify(getProof(tree, l.leaf), r.merkleRoot, l.leaf);
  check("every leaf verifies against root (OZ sorted-pair)", allVerify);

  const r2 = computeEpoch(snapshot);
  check("root is deterministic across runs", r.merkleRoot === r2.merkleRoot, r.merkleRoot);
  const b1 = stableStringify(buildBundle(snapshot, r));
  const b2 = stableStringify(buildBundle(snapshot, r2));
  check("reproducibility bundle is byte-identical across runs", b1 === b2);

  const sample = proofFor(r, r.leaves[0]!.account, r.leaves[0]!.kind);
  check("proofFor() returns a valid proof for a sample claimant", !!sample && sample.amount > 0n);
  check("wash-farm guardrail: no honest trader over-recovers", r.washFarmFlags.length === 0);

  console.log("\n=== INVARIANT SELF-CHECK — FERA TWAP (PT-8 freeze) ===");
  // synthetic observation sets (small minCardinality override to keep the mock tractable —
  // production uses the frozen FERA_TWAP_MIN_CARDINALITY = 5000)
  const flat = Array.from({ length: 100 }, (_, i) => ({ timestamp: 1000 + i * 10, priceE6: 50_000n }));
  const base = { windowStart: 1000, windowEnd: 2000, minCardinality: 50, prevEpochTwapE6: 55_000n };
  const tFlat = feraTwapE6(flat, base);
  check("flat window → TWAP == price, source=window", tFlat.twapE6 === 50_000n && tFlat.source === "window");

  // single-block flash print 10x is clamped to ±2% of the previous ACCEPTED value
  const spiked = flat.map((o, i) => (i === 50 ? { ...o, priceE6: 500_000n } : o));
  const tSpike = feraTwapE6(spiked, base);
  check(
    "±200bp/obs clamp: 10x flash print moves the 100-obs TWAP < 0.1%",
    tSpike.twapE6 < 50_050n && tSpike.clampedObservations >= 1,
    `twap=${tSpike.twapE6}, clampedObs=${tSpike.clampedObservations}`,
  );

  // sustained suppression floors at 70% of the previous epoch's TWAP (30% drop-clamp)
  const crashed = flat.map((o) => ({ ...o, priceE6: 10_000n }));
  const tCrash = feraTwapE6(crashed, base);
  check(
    "30% epoch drop-clamp: suppressed window floors at 0.7 × prev (38500)",
    tCrash.twapE6 === (55_000n * 7000n) / 10_000n && tCrash.dropClamped,
    `twap=${tCrash.twapE6}`,
  );

  // cardinality fail-static: 49 obs < minCardinality 50 → previous epoch's TWAP
  const thin = flat.slice(0, 49);
  const tThin = feraTwapE6(thin, base);
  check("cardinality fail-static: <minCardinality obs → previous epoch TWAP", tThin.twapE6 === 55_000n && tThin.source === "fail-static-cardinality");

  const path = writeBundle(snapshot, r);
  console.log(`\nreproducibility bundle written: ${path}`);

  console.log(`\n${failures === 0 ? "ALL INVARIANTS PASS ✅" : `${failures} INVARIANT(S) FAILED ❌`}`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
