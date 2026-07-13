// Public surface of the consensus-critical emissions pipeline (MASTER_SPEC v0.6 §9, D-M8).
export * from "./types";
export { aggregateEpoch } from "./aggregate";
export { buildClusters, computeSelfMatchExclusions, uniqueClusterTraders } from "./cluster";
export { computeEpoch, proofFor, logisticCap } from "./emissions";
export { computeLeaf, buildTree, getProof, verify, hashPair } from "./merkle";
export { buildBundle, writeBundle, stableStringify, computeScriptVersionHash } from "./bundle";
export { feraTwapE6 } from "./twap";
export * as config from "./config";

import { computeEpoch } from "./emissions";
import { writeBundle } from "./bundle";
import type { EpochSnapshot, EpochResult } from "./types";

/** Run one epoch end-to-end; optionally persist the reproducibility bundle. */
export function runEpoch(
  snapshot: EpochSnapshot,
  opts: { writeBundle?: boolean; outDir?: string } = {},
): { result: EpochResult; bundlePath?: string } {
  const result = computeEpoch(snapshot);
  if (opts.writeBundle) {
    const bundlePath = writeBundle(snapshot, result, opts.outDir);
    return { result, bundlePath };
  }
  return { result };
}
