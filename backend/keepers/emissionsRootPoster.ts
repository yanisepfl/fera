// KEEPER 3/4 — Emissions root poster (MASTER_SPEC §10, consensus-critical §9).
//
// TRIGGER: epoch end.
// ACTION: run the deterministic pipeline over the FROZEN epoch snapshot → Merkle root → write the
// reproducibility bundle → EmissionsController.finalizeEpoch(...) → Distributor.postRoot(...).
//
// F-11 / D-BK-12 / R-19 — CONTROLLER FUNDS EXACTLY ΣE_p:
//   finalizeEpoch now takes a leading `emissionRequested` = the pipeline's COMMITTED TOTAL. On-chain
//   that total is the Σ of the Merkle leaf amounts (`totalEsFeraWei` = trader+lp legs) — the exact
//   FERA the controller mints as esFERA backing and the exact number postRoot then asserts equals
//   `controller.emittedOf(epochId)` (Distributor.postRoot reverts EmittedMismatch otherwise). The
//   controller does NOT recompute the envelope: per D-BK-12 the pipeline's total may be strictly
//   BELOW min(cap, β·rev) (per-pool revenue locks leave un-emittable remainders), and INV-7 is an
//   inequality, so funding exactly ΣE_p is compliant. The treasury 10% leg is funded directly
//   OUTSIDE the Distributor path and is deliberately NOT part of `emissionRequested` (keeping the
//   R-19 `totalEsFera == emittedOf` bind exact). finalizeEpoch MUST run BEFORE postRoot.
//
// ON-CHAIN VERIFICATION BOUNDS (§10): "Distributor accepts ONE root per epoch; controller enforces
// the INV-7 amount cap." So this keeper cannot post a second/hotfixed root (Distributor.rootOf is
// write-once) and cannot exceed the emission cap (EmissionsController checks emissionRequested ≤
// min(cap, β×rev), INV-7 / PT-5). A missing keeper delays claims but never mis-mints (fail-static).
//
// NEVER-HOTFIX-A-POSTED-EPOCH (§9 + README policy): if a root is already posted for the epoch, this
// keeper REFUSES to recompute/repost — even if a bug is later found. The fix path is a NEW epoch or
// a governance action, never an in-place edit of a posted root. The bundle is append-only.
//
// PRE-POST SELF-CHECK: the keeper re-runs the pipeline twice and asserts byte-identical roots
// (determinism, §9) and that the on-chain reference cap ≥ emitted (INV-7) BEFORE it will submit.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { DistributorAbi } from "../abis/Distributor";
import { EmissionsControllerAbi } from "../abis/EmissionsController";
import { computeEpoch } from "../pipeline/emissions";
import { writeBundle } from "../pipeline/bundle";
import { runOnce, log, isUnset, type KeeperEnv } from "./common";
import type { EpochSnapshot } from "../pipeline/types";

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * Load the FROZEN epoch snapshot. In production the indexer builds this from the reorg-safe event
 * rows for the epoch's block range + pinned prices/TWAP/boost (see pipeline/types EpochSnapshot).
 * Here it is loaded from a file the snapshot-builder wrote (KEEPER_SNAPSHOT_FILE). TODO(deploy):
 * call the snapshot builder directly instead of reading a file.
 */
function loadSnapshot(epochId: bigint): EpochSnapshot | null {
  const file = process.env.KEEPER_SNAPSHOT_FILE ?? join(__dirname, "..", "bundles", `snapshot-${epochId}.json`);
  try {
    const raw = readFileSync(file, "utf8");
    // reviver: decimal strings that are pure integers → bigint (snapshots carry bigints as strings)
    return JSON.parse(raw, (_k, v) => (typeof v === "string" && /^-?\d+$/.test(v) ? BigInt(v) : v)) as EpochSnapshot;
  } catch {
    return null;
  }
}

async function tick(env: KeeperEnv): Promise<void> {
  const distributor = process.env.FERA_DISTRIBUTOR_ADDRESS;
  const controller = process.env.FERA_EMISSIONS_ADDRESS;
  if (isUnset(distributor) || isUnset(controller)) {
    log("root-poster", "warn", "distributor/controller unset — skipping (fail-static)");
    return;
  }

  // Which epoch just ended? currentEpoch()-1 is the most recent CLOSED epoch.
  const current = (await env.publicClient.readContract({
    address: controller as `0x${string}`,
    abi: EmissionsControllerAbi,
    functionName: "currentEpoch",
    args: [],
  })) as bigint;
  if (current === 0n) {
    log("root-poster", "info", "no closed epoch yet");
    return;
  }
  const epochId = current - 1n;

  // never-hotfix: refuse if a root already exists on-chain.
  const existing = (await env.publicClient.readContract({
    address: distributor as `0x${string}`,
    abi: DistributorAbi,
    functionName: "rootOf",
    args: [epochId],
  })) as `0x${string}`;
  const ZERO32 = "0x" + "00".repeat(32);
  if (existing && existing.toLowerCase() !== ZERO32) {
    log("root-poster", "info", "root already posted — refusing to recompute (never-hotfix)", { epochId, existing });
    return;
  }

  const snapshot = loadSnapshot(epochId);
  if (!snapshot) {
    log("root-poster", "warn", "no frozen snapshot available — cannot post (fail-static)", { epochId });
    return;
  }

  // determinism self-check (§9): two independent runs must agree bit-for-bit.
  const r1 = computeEpoch(snapshot);
  const r2 = computeEpoch(snapshot);
  if (r1.merkleRoot !== r2.merkleRoot) {
    throw new Error(`non-deterministic root for epoch ${epochId}: ${r1.merkleRoot} != ${r2.merkleRoot}`);
  }

  // INV-7 pre-check against the authoritative on-chain cap (belt-and-braces; controller re-checks).
  if (r1.emittedFeraWei > r1.capFeraWei) {
    throw new Error(`INV-7 violation: emitted ${r1.emittedFeraWei} > cap ${r1.capFeraWei}`);
  }

  const bundlePath = writeBundle(snapshot, r1);
  log("root-poster", "info", "bundle written", { epochId, root: r1.merkleRoot, totalEsFera: r1.totalEsFeraWei, bundlePath });

  // F-11: the committed total funded on-chain is Σ leaf amounts (== postRoot's totalEsFera). The
  // controller mints exactly this and postRoot asserts totalEsFera == emittedOf (R-19).
  const emissionRequested = r1.totalEsFeraWei;

  if (env.dryRun || !env.walletClient || !env.account) {
    log("root-poster", "info", "DRY-RUN would finalizeEpoch + postRoot", {
      epochId,
      root: r1.merkleRoot,
      emissionRequested,
      revenueValuedInFera: r1.revenueValuedInFeraWei,
      feraTwap: r1.feraTwapE6,
    });
    return;
  }

  // F-11 — finalizeEpoch(emissionRequested = ΣE_p) BEFORE postRoot. Idempotent: if the epoch is
  // already finalized (e.g. the redundant keeper won), verify the funded envelope matches this
  // snapshot's committed total (a mismatch means the snapshot changed → abort, never repost).
  const alreadyFinalized = (await env.publicClient.readContract({
    address: controller as `0x${string}`,
    abi: EmissionsControllerAbi,
    functionName: "finalized",
    args: [epochId],
  })) as boolean;
  if (!alreadyFinalized) {
    const finalizeHash = await env.walletClient.writeContract({
      chain: null,
      account: env.account,
      address: controller as `0x${string}`,
      abi: EmissionsControllerAbi,
      functionName: "finalizeEpoch",
      args: [epochId, emissionRequested, r1.revenueValuedInFeraWei, r1.feraTwapE6],
    });
    log("root-poster", "info", "finalizeEpoch submitted (controller funds exactly ΣE_p; D-BK-12/R-19)", {
      epochId,
      emissionRequested,
      revenueValuedInFera: r1.revenueValuedInFeraWei,
      hash: finalizeHash,
    });
  } else {
    const funded = (await env.publicClient.readContract({
      address: controller as `0x${string}`,
      abi: EmissionsControllerAbi,
      functionName: "emittedOf",
      args: [epochId],
    })) as bigint;
    if (funded !== emissionRequested) {
      throw new Error(
        `epoch ${epochId} already finalized with emittedOf=${funded} but this snapshot commits ${emissionRequested} — snapshot drift, refusing to post`,
      );
    }
    log("root-poster", "info", "epoch already finalized; funded envelope matches committed ΣE_p", { epochId, funded });
  }

  const hash = await env.walletClient.writeContract({
    chain: null,
    account: env.account,
    address: distributor as `0x${string}`,
    abi: DistributorAbi,
    functionName: "postRoot",
    args: [epochId, r1.merkleRoot, emissionRequested],
  });
  log("root-poster", "info", "postRoot submitted (totalEsFera == emittedOf; Distributor one root/epoch)", {
    epochId,
    root: r1.merkleRoot,
    hash,
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runOnce("root-poster", tick).then((code) => process.exit(code));
}

export { tick as emissionsRootPosterTick };
