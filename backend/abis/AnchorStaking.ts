// AnchorStaking ABI — RECONCILED against contracts/out/AnchorStaking.sol v2 (BK-1, 2026-07-12).
// Events (Staked/Unstaked/RevenueShareClaimed) match §6. Reads reconciled: `boostOf` is `pure`
// on-chain (output `boostWad`); the ASSUMED `multiplierPoints(address)` getter does NOT exist and
// was removed (the /staking `multiplierPoints` field is a view snapshot tracked off-chain, not this
// call). Added the v2 revenue-share ALLOWLIST surface (addRewardToken/isRewardToken/rewardTokens…)
// + stake reads used by the /staking endpoint and revenue-share reconciliation.
export const AnchorStakingAbi = [
  {
    type: "event",
    name: "Staked",
    inputs: [
      { name: "account", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "lockWeeks", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "Unstaked",
    inputs: [
      { name: "account", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "RevenueShareClaimed",
    inputs: [
      { name: "account", type: "address", indexed: true },
      { name: "token", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  // ---- Reads (reconciled to contracts/out v2). ----
  {
    type: "function",
    name: "boostOf",
    stateMutability: "pure", // pure on-chain (boost is a deterministic fn of lock state, not storage)
    inputs: [{ name: "account", type: "address" }],
    // boost in 1e18 fixed point: 1e18 = 1x (no boost), 2e18 = max 2x.
    outputs: [{ name: "boostWad", type: "uint256" }],
  },
  {
    type: "function",
    name: "stakedOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "lockUntil",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "totalStaked",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  // v2 revenue-share ALLOWLIST (SEC-hardened: only allowlisted tokens accrue revenue share).
  {
    type: "function",
    name: "isRewardToken",
    stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "rewardTokenCount",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "rewardTokens",
    stateMutability: "view",
    inputs: [{ name: "index", type: "uint256" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "claimableRevenue",
    stateMutability: "view",
    inputs: [
      { name: "account", type: "address" },
      { name: "token", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;
