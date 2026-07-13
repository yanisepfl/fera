// EsFera ABI — MASTER_SPEC §6 events. RECONCILED against contracts/out/EsFera.sol v2 (BK-1,
// 2026-07-12): VestStarted / InstantExit / ForfeitRouted match; the F-8 batch's
// `VestClaimed(address indexed account, uint256 amount)` (D-BK-9) is now present on-chain and
// added below so the indexer can distinguish claimable from vested.
export const EsFeraAbi = [
  {
    type: "event",
    name: "VestClaimed",
    inputs: [
      { name: "account", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "VestStarted",
    inputs: [
      { name: "account", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "startTs", type: "uint256", indexed: false },
      { name: "endTs", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "InstantExit",
    inputs: [
      { name: "account", type: "address", indexed: true },
      { name: "esBurned", type: "uint256", indexed: false },
      { name: "feraOut", type: "uint256", indexed: false },
      { name: "haircut", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "ForfeitRouted",
    inputs: [
      { name: "burned", type: "uint256", indexed: false },
      { name: "toStakers", type: "uint256", indexed: false },
      { name: "toRevenue", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
] as const;
