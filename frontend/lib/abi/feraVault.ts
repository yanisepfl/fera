/**
 * FeraVault ABI — ONLY the fragments the frontend calls, copied VERBATIM from
 * backend/abis/FeraVault.ts (the generated forge artifact, source of truth —
 * BK-1 regen 2026-07-16). Deployed on Robinhood Chain (4663) at config/pools.ts#VAULT.
 *
 * Do not hand-edit fragment contents: if the contract changes, re-run the BK-1 ABI
 * regen in backend/ and re-copy the fragments here. Keeping the app's bundle to the
 * handful of entry points it uses (instead of importing the 2,200-line full ABI)
 * is deliberate.
 */
export const feraVaultAbi = [
  {
    type: "function",
    name: "deposit",
    inputs: [
      { name: "id", type: "bytes32", internalType: "PoolId" },
      { name: "t", type: "uint8", internalType: "uint8" },
      { name: "amount0", type: "uint256", internalType: "uint256" },
      { name: "amount1", type: "uint256", internalType: "uint256" },
      { name: "minShares", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "sharesMinted", type: "uint256", internalType: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "withdraw",
    inputs: [
      { name: "id", type: "bytes32", internalType: "PoolId" },
      { name: "t", type: "uint8", internalType: "uint8" },
      { name: "shares", type: "uint256", internalType: "uint256" },
      { name: "minAmount0", type: "uint256", internalType: "uint256" },
      { name: "minAmount1", type: "uint256", internalType: "uint256" },
    ],
    outputs: [
      { name: "amount0", type: "uint256", internalType: "uint256" },
      { name: "amount1", type: "uint256", internalType: "uint256" },
    ],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "withdrawSingle",
    inputs: [
      { name: "id", type: "bytes32", internalType: "PoolId" },
      { name: "t", type: "uint8", internalType: "uint8" },
      { name: "shares", type: "uint256", internalType: "uint256" },
      { name: "tokenOut", type: "address", internalType: "address" },
      { name: "minOut", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "amountOut", type: "uint256", internalType: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "quoteNav",
    inputs: [
      { name: "id", type: "bytes32", internalType: "PoolId" },
      { name: "t", type: "uint8", internalType: "uint8" },
    ],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "depositsPaused",
    inputs: [{ name: "id", type: "bytes32", internalType: "PoolId" }],
    outputs: [{ name: "", type: "bool", internalType: "bool" }],
    stateMutability: "view",
  },
  {
    // Public mapping getter: lastDepositTs[poolId][tranche][account] → unix seconds of the
    // account's last deposit into that (pool, tranche). Drives the REAL 1h withdraw-cooldown
    // countdown (FeraConstants.DEPOSIT_COOLDOWN_SEC = 3600; withdrawing earlier reverts
    // CooldownActive). NOTE: the generated getter widens the uint8 tranche key to uint256.
    type: "function",
    name: "lastDepositTs",
    inputs: [
      { name: "", type: "bytes32", internalType: "PoolId" },
      { name: "", type: "uint256", internalType: "uint256" },
      { name: "", type: "address", internalType: "address" },
    ],
    outputs: [{ name: "", type: "uint64", internalType: "uint64" }],
    stateMutability: "view",
  },
  {
    // General share-token getter for ANY (pool, tranche) — createBaseLimitPool initializes
    // both tranches' FeraShare clones at pool creation, so this resolves tranche 1's address
    // live instead of requiring every pool's tranche-1 clone hardcoded in config/pools.ts.
    type: "function",
    name: "shareToken",
    inputs: [
      { name: "id", type: "bytes32", internalType: "PoolId" },
      { name: "t", type: "uint8", internalType: "uint8" },
    ],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
] as const;
