// FeraHook ABI — RECONCILED against contracts/out/FeraHook.sol v2 (BK-1, 2026-07-12).
// EVENTS match on-chain: Swap, PoolRegistered (beforeInitialize, BK-2), JitPenaltyApplied (D-14).
//
// ⚠️ getDynamicFee DRIFT (UNRECONCILED — see OPEN_DECISIONS.md BK-1): the on-chain hook exposes NO
//   `getDynamicFee(poolId)` view. The applied fee comes out of `beforeSwap`; a live read must go via
//   the v4 PoolManager/StateLibrary slot0 lpFee, or the API falls back to the last indexed Swap
//   `lpFeePips`. api/liveFee.ts already has that indexed fallback. The real hook read available today
//   is `regimeOf(poolId)` (added below). Kept `getDynamicFee` so liveFee.ts compiles; flagged.
export const FeraHookAbi = [
  {
    type: "event",
    name: "Swap",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "trader", type: "address", indexed: true },
      { name: "amount0", type: "int256", indexed: false },
      { name: "amount1", type: "int256", indexed: false },
      { name: "lpFeePips", type: "uint24", indexed: false },
      { name: "feeAmount", type: "uint256", indexed: false },
      { name: "zeroForOne", type: "bool", indexed: false },
      { name: "regime", type: "uint8", indexed: false },
    ],
    anonymous: false,
  },
  // F-8 batch (MASTER_SPEC v0.6 §6): emitted in beforeInitialize — kills the env-sourced pool
  // metadata (BK-2). Env registry FERA_POOL_TOKENS remains the decimals/symbols fallback.
  {
    type: "event",
    name: "PoolRegistered",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "token0", type: "address", indexed: false },
      { name: "token1", type: "address", indexed: false },
      { name: "regime", type: "uint8", indexed: false },
    ],
    anonymous: false,
  },
  // F-8 batch (D-14 fee-forfeiture JIT guard). Emitting contract ASSUMED to be the hook (the
  // OZ LiquidityPenaltyHook pattern forfeits in afterRemoveLiquidity) — §6 does not name it;
  // flagged in OPEN_DECISIONS.md (D-BK-7). Forfeited fees are donated to in-range LPs.
  {
    type: "event",
    name: "JitPenaltyApplied",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "owner", type: "address", indexed: true },
      { name: "fee0Forfeited", type: "uint256", indexed: false },
      { name: "fee1Forfeited", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  // ⚠️ ASSUMED — no on-chain counterpart (see header). Live fee read must migrate to StateLibrary
  // slot0 lpFee; api/liveFee.ts falls back to the last indexed Swap.lpFeePips today.
  {
    type: "function",
    name: "getDynamicFee",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ name: "lpFeePips", type: "uint24" }],
  },
  // Real v2 read: regime (0 MEME / 1 RWA) per pool.
  {
    type: "function",
    name: "regimeOf",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const;
