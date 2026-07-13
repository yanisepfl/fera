// EmissionsController ABI — RECONCILED against contracts/out/EmissionsController.sol v2
// (BK-1, 2026-07-12). Carries the §6 EpochFinalized event + the reads/writes the root-poster
// keeper needs, matched bit-for-bit to the compiled artifact.
//
// F-11: `finalizeEpoch` now takes a leading `emissionRequested` (= the pipeline's committed total,
// Σ leaf amounts) so the controller FUNDS EXACTLY that (D-BK-12 / R-19) rather than recomputing the
// envelope. Drift fixed: the old ASSUMED `epochEndsAt(uint256)` did not exist on-chain — the real
// getter is `epochEnd(uint256)`.
export const EmissionsControllerAbi = [
  {
    type: "event",
    name: "EpochFinalized",
    inputs: [
      { name: "epochId", type: "uint256", indexed: true },
      { name: "capAmount", type: "uint256", indexed: false },
      { name: "revenueBound", type: "uint256", indexed: false },
      { name: "emitted", type: "uint256", indexed: false },
      { name: "feraTwap", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  // Epoch clock reads.
  {
    type: "function",
    name: "currentEpoch",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "epochEnd", // was ASSUMED `epochEndsAt` — reconciled to the real name (BK-1).
    stateMutability: "view",
    inputs: [{ name: "epochId", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "capAt", // cumulative emittable up to time t (INV-7 first arm).
    stateMutability: "view",
    inputs: [{ name: "t", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "beta", // β (1e18-fixed) — INV-7 second arm.
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  // R-19 / D-M9 C2 reads — the Distributor binds its posted totalEsFera to `emittedOf(epochId)`.
  {
    type: "function",
    name: "finalized",
    stateMutability: "view",
    inputs: [{ name: "epochId", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "emittedOf",
    stateMutability: "view",
    inputs: [{ name: "epochId", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  // F-11: the root-poster funds the epoch by passing the pipeline's committed total
  // `emissionRequested` (= Σ leaf amounts, which MUST fit inside min(cap, β·revenueValuedInFera)).
  // The controller mints exactly `emitted == emissionRequested` as esFERA backing (D-BK-12).
  {
    type: "function",
    name: "finalizeEpoch",
    stateMutability: "nonpayable",
    inputs: [
      { name: "epochId", type: "uint256" },
      { name: "emissionRequested", type: "uint256" },
      { name: "revenueValuedInFera", type: "uint256" },
      { name: "feraTwap", type: "uint256" },
    ],
    outputs: [{ name: "emitted", type: "uint256" }],
  },
] as const;
