/**
 * FeraHook ABI — ONLY the fragment the frontend calls, copied VERBATIM from
 * backend/abis/FeraHook.ts (the generated forge artifact, source of truth —
 * BK-1 regen 2026-07-16). Deployed on Robinhood Chain (4663) at config/pools.ts#HOOK.
 */
export const feraHookAbi = [
  {
    type: "function",
    name: "getDynamicFee",
    inputs: [{ name: "poolId", type: "bytes32", internalType: "PoolId" }],
    outputs: [{ name: "lpFeePips", type: "uint24", internalType: "uint24" }],
    stateMutability: "view",
  },
] as const;
