// Distributor ABI — RECONCILED against contracts/out/Distributor.sol v2 (BK-1, 2026-07-12): the
// RootPosted/Claimed events + postRoot(epochId,root,totalEsFera) / rootOf / isClaimed all match
// on-chain. postRoot reverts unless totalEsFera == controller.emittedOf(epochId) (R-19) — see the
// root-poster keeper's F-11 flow.
export const DistributorAbi = [
  {
    type: "event",
    name: "RootPosted",
    inputs: [
      { name: "epochId", type: "uint256", indexed: true },
      { name: "merkleRoot", type: "bytes32", indexed: false },
      { name: "totalEsFera", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "Claimed",
    inputs: [
      { name: "epochId", type: "uint256", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "kind", type: "uint8", indexed: false }, // 0 traderRebate 1 lpReward
      { name: "amount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  // ---- ASSUMED write/read, pending contracts/. Distributor accepts ONE root per epoch. ----
  {
    type: "function",
    name: "postRoot",
    stateMutability: "nonpayable",
    inputs: [
      { name: "epochId", type: "uint256" },
      { name: "merkleRoot", type: "bytes32" },
      { name: "totalEsFera", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "rootOf",
    stateMutability: "view",
    inputs: [{ name: "epochId", type: "uint256" }],
    outputs: [{ name: "merkleRoot", type: "bytes32" }],
  },
  {
    type: "function",
    name: "isClaimed",
    stateMutability: "view",
    inputs: [
      { name: "epochId", type: "uint256" },
      { name: "account", type: "address" },
      { name: "kind", type: "uint8" },
    ],
    outputs: [{ name: "claimed", type: "bool" }],
  },
] as const;
