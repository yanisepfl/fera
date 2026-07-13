// RevenueDistributor ABI — RECONCILED against contracts/out/RevenueDistributor.sol v2 (BK-1,
// 2026-07-12): RevenueReceived / RevenueSplit events match on-chain exactly.
export const RevenueDistributorAbi = [
  {
    type: "event",
    name: "RevenueReceived",
    inputs: [
      { name: "token", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "RevenueSplit",
    inputs: [
      { name: "token", type: "address", indexed: true },
      { name: "toStakers", type: "uint256", indexed: false },
      { name: "toTreasury", type: "uint256", indexed: false },
      { name: "toOps", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
] as const;
