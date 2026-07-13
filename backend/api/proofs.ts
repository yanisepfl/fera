// Merkle-proof lookup for GET /epochs/:id/proof/:account.
//
// Proofs are produced by the CONSENSUS-CRITICAL pipeline (MASTER_SPEC §9), not the indexer, and
// published in the per-epoch reproducibility bundle (backend/bundles/epoch-<id>.json). The API
// serves proofs by reading that append-only bundle — the SAME artifact the root-poster keeper
// posts on-chain — so the proof the Frontend claims with is byte-identical to the posted tree.
// NEVER recompute proofs on the fly from live state (that could drift from the posted root).

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import type { Address, Hex, ProofEntry, ProofResponse } from "./shapes";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BUNDLE_DIR = process.env.FERA_BUNDLE_DIR ?? join(__dirname, "..", "bundles");

interface BundleClaim {
  account: string;
  kind: number;
  amount: string;
  proof: Hex[];
}
interface BundleFile {
  epochId: string;
  root: Hex;
  claims: BundleClaim[];
}

function loadBundle(epochId: string): BundleFile | null {
  try {
    const raw = readFileSync(join(BUNDLE_DIR, `epoch-${epochId}.json`), "utf8");
    return JSON.parse(raw) as BundleFile;
  } catch {
    return null;
  }
}

/** All claim leaves for `account` in epoch `epochId` (0, 1, or 2 — trader and/or lp). */
export function proofsFor(epochId: string, account: Address, kind?: number): ProofResponse {
  const bundle = loadBundle(epochId);
  if (!bundle) return { epochId, account, root: null, claims: [] };
  const acct = account.toLowerCase();
  const claims: ProofEntry[] = bundle.claims
    .filter((c) => c.account.toLowerCase() === acct && (kind === undefined || c.kind === kind))
    .map((c) => ({ kind: c.kind, amount: c.amount, proof: c.proof }));
  return { epochId, account, root: bundle.root, claims };
}
