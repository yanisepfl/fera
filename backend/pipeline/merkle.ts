// Merkle tree — MASTER_SPEC §9 data contract, EXACT.
//
//   leaf = keccak256(abi.encode(uint256 epochId, address account, uint8 kind, uint256 amount))
//   internal nodes: sorted-pair hashing (OpenZeppelin `MerkleProof` convention)
//   amounts in esFERA wei (18 dec)
//
// IMPORTANT: this is a SINGLE-hash leaf, matching the spec literally. OpenZeppelin's
// `StandardMerkleTree` double-hashes leaves; we deliberately do NOT use it, so that the
// on-chain Distributor can recompute the leaf as a single keccak256(abi.encode(...)) and verify
// with `MerkleProof.verify` (sorted pairs). Proof generation here folds identically to
// `MerkleProof.verify`, so any tree shape (incl. odd node counts via promotion) verifies.

import { keccak256, encodeAbiParameters, concatHex } from "viem";
import type { Hex, Address, Kind } from "./types";

/** leaf = keccak256(abi.encode(uint256 epochId, address account, uint8 kind, uint256 amount)) */
export function computeLeaf(
  epochId: bigint,
  account: Address,
  kind: Kind,
  amount: bigint,
): Hex {
  const encoded = encodeAbiParameters(
    [{ type: "uint256" }, { type: "address" }, { type: "uint8" }, { type: "uint256" }],
    [epochId, account, kind, amount],
  );
  return keccak256(encoded);
}

/** Sorted-pair parent hash: keccak256(min(a,b) ++ max(a,b)). OZ convention. */
export function hashPair(a: Hex, b: Hex): Hex {
  return a.toLowerCase() <= b.toLowerCase()
    ? keccak256(concatHex([a, b]))
    : keccak256(concatHex([b, a]));
}

export interface MerkleTree {
  root: Hex;
  leaves: Hex[]; // sorted, deduped order used to build the tree
  layers: Hex[][];
}

/**
 * Build a sorted-pair Merkle tree. Leaves are sorted ascending (deterministic) and duplicates
 * rejected (a duplicate leaf would mean two identical (epochId,account,kind,amount) rows — an
 * upstream bug). Odd nodes are promoted unchanged to the next layer.
 */
export function buildTree(rawLeaves: Hex[]): MerkleTree {
  if (rawLeaves.length === 0) throw new Error("merkle: empty leaf set");
  const leaves = [...rawLeaves].sort((a, b) => (a.toLowerCase() < b.toLowerCase() ? -1 : 1));
  for (let i = 1; i < leaves.length; i++) {
    if (leaves[i]!.toLowerCase() === leaves[i - 1]!.toLowerCase())
      throw new Error(`merkle: duplicate leaf ${leaves[i]}`);
  }
  const layers: Hex[][] = [leaves];
  let layer = leaves;
  while (layer.length > 1) {
    const next: Hex[] = [];
    for (let i = 0; i < layer.length; i += 2) {
      if (i + 1 === layer.length) next.push(layer[i]!); // promote odd node
      else next.push(hashPair(layer[i]!, layer[i + 1]!));
    }
    layers.push(next);
    layer = next;
  }
  return { root: layer[0]!, leaves, layers };
}

/** Proof for the leaf at its sorted position. Throws if the leaf is absent. */
export function getProof(tree: MerkleTree, leaf: Hex): Hex[] {
  let idx = tree.leaves.findIndex((l) => l.toLowerCase() === leaf.toLowerCase());
  if (idx === -1) throw new Error(`merkle: leaf not in tree ${leaf}`);
  const proof: Hex[] = [];
  for (let l = 0; l < tree.layers.length - 1; l++) {
    const layer = tree.layers[l]!;
    const sibling = idx ^ 1;
    if (sibling < layer.length) proof.push(layer[sibling]!);
    idx = idx >> 1;
  }
  return proof;
}

/** OpenZeppelin-equivalent verify (sorted-pair fold). Used by tests/dry-run self-check. */
export function verify(proof: Hex[], root: Hex, leaf: Hex): boolean {
  let computed = leaf;
  for (const p of proof) computed = hashPair(computed, p);
  return computed.toLowerCase() === root.toLowerCase();
}
