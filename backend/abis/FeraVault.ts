// FeraVault ABI — RECONCILED against contracts/out/FeraVault.sol v2 (BK-1, 2026-07-12).
// EVENTS all match on-chain, incl. the F-8 batch `uint8 tranche` (LAST field) on
// Deposit/Withdraw/FeesCollected/SharePriceCheckpoint (D-12) and StrategyAction (no tranche).
//
// ⚠️ KEEPER READ/WRITE DRIFT (UNRECONCILED — see OPEN_DECISIONS.md BK-1, routed to Contracts+Backend):
//   the ASSUMED keeper fragments below do NOT match the compiled v2 surface. On-chain the writes are
//   setHoliday(id,on) / setEventWindow(id,on) / recenter(id,tl,tu,hash) / recenterMeme(id,hash) /
//   widen(id,tl,tu,hash) / drip(id,t) / collectFees(id,t); reads are pendingFees(id,t) / regimeOf(id).
//   There is NO on-chain `isMarketOpen` / `isEventWindow` VIEW getter and NO generic
//   `executeStrategy` — the RWA keeper cluster (marketHours/rwaStrategy/eventCalendar) + ops
//   reconcile need a joint rewire (and Contracts must add the missing view getters). Kept as-is so
//   the keepers compile; flagged rather than silently mis-signed.
export const FeraVaultAbi = [
  {
    type: "event",
    name: "Deposit",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "user", type: "address", indexed: true },
      { name: "amount0", type: "uint256", indexed: false },
      { name: "amount1", type: "uint256", indexed: false },
      { name: "sharesMinted", type: "uint256", indexed: false },
      { name: "tranche", type: "uint8", indexed: false }, // F-8 (D-12)
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "Withdraw",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "user", type: "address", indexed: true },
      { name: "amount0", type: "uint256", indexed: false },
      { name: "amount1", type: "uint256", indexed: false },
      { name: "sharesBurned", type: "uint256", indexed: false },
      { name: "tranche", type: "uint8", indexed: false }, // F-8 (D-12)
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "FeesCollected",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "fee0", type: "uint256", indexed: false },
      { name: "fee1", type: "uint256", indexed: false },
      { name: "perfFee0", type: "uint256", indexed: false },
      { name: "perfFee1", type: "uint256", indexed: false },
      { name: "tranche", type: "uint8", indexed: false }, // F-8 (D-12, INV-15)
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "StrategyAction",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      // kind: 0 initialMint 1 recenter(RWA) 2 widen(RWA off-hours) 3 partialWithdraw(RWA)
      //       4 compoundInPlace 5 dripDeploy (F-8 — MEME fee-income no-swap band, INV-5″)
      //       6 bandConsolidate (F-8 — D-17 fee-band merges; now registered in MASTER_SPEC §6.
      //        Like kind 5 it does NOT move the principal headline band; indexer stores kind raw)
      { name: "kind", type: "uint8", indexed: false },
      { name: "tickLower", type: "int24", indexed: false },
      { name: "tickUpper", type: "int24", indexed: false },
      { name: "oraclePrice", type: "uint256", indexed: false },
      { name: "justificationHash", type: "bytes32", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "SharePriceCheckpoint",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "sharePriceX96", type: "uint256", indexed: false },
      { name: "epochId", type: "uint256", indexed: false },
      { name: "tranche", type: "uint8", indexed: false }, // F-8 (D-12)
    ],
    anonymous: false,
  },
  // ---- Reads / writes used by keepers + reconciliation. ASSUMED, pending contracts/. ----
  {
    type: "function",
    name: "isMarketOpen",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ name: "open", type: "bool" }],
  },
  {
    type: "function",
    name: "setHolidayFlag",
    stateMutability: "nonpayable",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "isHoliday", type: "bool" },
    ],
    outputs: [],
  },
  // Event-calendar guard (MASTER_SPEC v0.6 §10 new row, D-M11): keeper flags a scheduled-event
  // session; the Vault enforces the forced widen / partial withdraw up to the HARDCODED bound
  // RWA_EVENT_WITHDRAW_FRAC = 0.80 (keeper input is bounded + fail-static). ASSUMED signature.
  {
    type: "function",
    name: "setEventWindowFlag",
    stateMutability: "nonpayable",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "active", type: "bool" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "isEventWindow",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ name: "active", type: "bool" }],
  },
  {
    type: "function",
    name: "executeStrategy",
    stateMutability: "nonpayable",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "kind", type: "uint8" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "accruedFees",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "fee0", type: "uint256" },
      { name: "fee1", type: "uint256" },
    ],
  },
] as const;
