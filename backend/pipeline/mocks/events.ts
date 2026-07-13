// Mocked events for a full epoch — used by the dry-run (pipeline/dryrun.ts).
//
// v2 scenario (exercises the D-M8 ordering, the 85/5/10 split, multi-pool boost
// normalization, tranches, and the funding-cluster self-match exclusion):
//
//   POOL_MEME (MEME/WETH, regime 0, single tranche 0 — D-16)
//     LPs      : LP1 (honest), LP2 (honest, 1.5x boost), WHALE (self-dealer, 2x boost, 60% of
//                shares), LP4 (receives a share TRANSFER from LP1 mid-epoch)
//     traders  : T1 (honest whale, 2x boost — must NOT affect the trader leaf, Decision B),
//                T2 (honest small), WASH + WASH2 (WHALE's funding cluster — wash flow),
//                ROUTER (unclusterable settlement contract — default-allow external flow)
//     cluster  : WHALE →funds→ WASH →funds→ WASH2  ⇒ depth-2 cluster {WHALE, WASH, WASH2}
//                LP1 →share-transfer→ LP4          ⇒ cluster {LP1, LP4} (harmless, no trades)
//   POOL_RWA (NVDA/USDG, regime 1, tranches 0 Core + 1 Anchor — D-12/D-16)
//     LPs      : LP1 (tranche 0), LP2 (tranche 1, 1.5x boost)
//     traders  : T1, T2 (honest)
//     poolCap  : an extra absolute cap BELOW the revenue lock — exercises "the per-pool lock
//                is FINAL; the gap is un-emitted, never redistributed" (emitted < epochTotal).
//
// This is TEST DATA ONLY. Real snapshots are built by the indexer from on-chain events.

import type { EpochSnapshot, Hex, Address } from "../types";

export const POOL_MEME = ("0x" + "aa".repeat(32)) as Hex; // MEME / WETH
export const POOL_RWA = ("0x" + "bb".repeat(32)) as Hex; // NVDA / USDG

const MEME = "0x1000000000000000000000000000000000000001" as Address; // 18d, $0.01
const WETH = "0x2000000000000000000000000000000000000002" as Address; // 18d, $3000
const NVDA = "0x3000000000000000000000000000000000000003" as Address; // 18d, $120
const USDG = "0x4000000000000000000000000000000000000004" as Address; // 6d,  $1

export const T1 = "0x1111111111111111111111111111111111111111" as Address; // honest trader whale
export const T2 = "0x2222222222222222222222222222222222222222" as Address; // honest trader small
export const ROUTER = "0x5555555555555555555555555555555555555555" as Address; // unclusterable
export const LP1 = "0xaaa1000000000000000000000000000000000001" as Address; // honest LP
export const LP2 = "0xaaa2000000000000000000000000000000000002" as Address; // LP + staker (1.5x)
export const LP4 = "0xaaa4000000000000000000000000000000000004" as Address; // transfer recipient
export const WHALE = "0xbbb1000000000000000000000000000000000001" as Address; // self-dealer LP (2x)
export const WASH = "0xbbb2000000000000000000000000000000000002" as Address; // funded by WHALE
export const WASH2 = "0xbbb3000000000000000000000000000000000003" as Address; // funded by WASH
const CEX1 = "0xccc1000000000000000000000000000000000001" as Address; // distinct honest funders
const CEX2 = "0xccc2000000000000000000000000000000000002" as Address;
const CEX3 = "0xccc3000000000000000000000000000000000003" as Address;

const WAD = 10n ** 18n;
const e6 = (usd: number) => BigInt(Math.round(usd * 1e6));

export function mockEpochSnapshot(epochId = 0n): EpochSnapshot {
  return {
    epochId,
    fromBlock: 100_000n,
    toBlock: 200_000n,
    epochEndTs: 7000,

    // ---- Swap events (fees PAID; feeAmount in the INPUT token) ----
    swaps: [
      // MEME pool. T1: 0.003 WETH fee = $9.
      { poolId: POOL_MEME, trader: T1, amount0: 0n, amount1: -10n * WAD, lpFeePips: 3400, feeAmount: 3n * 10n ** 15n, zeroForOne: false, regime: 0, blockNumber: 110_000n, timestamp: 1500, logIndex: 0 },
      // T2: 100 MEME fee = $1.
      { poolId: POOL_MEME, trader: T2, amount0: 5000n * WAD, amount1: 0n, lpFeePips: 30000, feeAmount: 100n * WAD, zeroForOne: true, regime: 0, blockNumber: 120_000n, timestamp: 2500, logIndex: 0 },
      // WASH (WHALE cluster, depth 1): 0.002 WETH fee = $6 — wash flow.
      { poolId: POOL_MEME, trader: WASH, amount0: 0n, amount1: -6n * WAD, lpFeePips: 3400, feeAmount: 2n * 10n ** 15n, zeroForOne: false, regime: 0, blockNumber: 125_500n, timestamp: 2600, logIndex: 0 },
      // WASH2 (WHALE cluster, depth 2): 400 MEME fee = $4 — wash flow.
      { poolId: POOL_MEME, trader: WASH2, amount0: 20_000n * WAD, amount1: 0n, lpFeePips: 30000, feeAmount: 400n * WAD, zeroForOne: true, regime: 0, blockNumber: 126_000n, timestamp: 2700, logIndex: 0 },
      // ROUTER (unclusterable — default-allow): 500 MEME fee = $5, counts as external.
      { poolId: POOL_MEME, trader: ROUTER, amount0: 25_000n * WAD, amount1: 0n, lpFeePips: 30000, feeAmount: 500n * WAD, zeroForOne: true, regime: 0, blockNumber: 127_000n, timestamp: 2800, logIndex: 0 },
      // RWA pool. T1: 2 USDG fee = $2.
      { poolId: POOL_RWA, trader: T1, amount0: 0n, amount1: -20_000n * 10n ** 6n, lpFeePips: 200, feeAmount: 2n * 10n ** 6n, zeroForOne: false, regime: 1, blockNumber: 140_000n, timestamp: 4000, logIndex: 0 },
      // T2: ~0.033 NVDA fee = $4.
      { poolId: POOL_RWA, trader: T2, amount0: 33n * 10n ** 15n, amount1: 0n, lpFeePips: 3000, feeAmount: 33n * 10n ** 15n, zeroForOne: true, regime: 1, blockNumber: 150_000n, timestamp: 4500, logIndex: 0 },
    ],

    // ---- Deposits (per pool, per tranche — F-8/D-12) ----
    deposits: [
      { poolId: POOL_MEME, tranche: 0, user: LP1, amount0: 0n, amount1: 5n * WAD, sharesMinted: 1000n * WAD, blockNumber: 100_500n, timestamp: 1000, logIndex: 0 },
      { poolId: POOL_MEME, tranche: 0, user: WHALE, amount0: 0n, amount1: 15n * WAD, sharesMinted: 3000n * WAD, blockNumber: 100_600n, timestamp: 1000, logIndex: 1 },
      { poolId: POOL_MEME, tranche: 0, user: LP2, amount0: 0n, amount1: 5n * WAD, sharesMinted: 1000n * WAD, blockNumber: 105_000n, timestamp: 2000, logIndex: 0 },
      { poolId: POOL_RWA, tranche: 0, user: LP1, amount0: 0n, amount1: 10_000n * 10n ** 6n, sharesMinted: 500n * WAD, blockNumber: 101_000n, timestamp: 1200, logIndex: 0 },
      { poolId: POOL_RWA, tranche: 1, user: LP2, amount0: 50n * WAD, amount1: 0n, sharesMinted: 400n * WAD, blockNumber: 101_500n, timestamp: 1300, logIndex: 0 },
    ],

    withdraws: [
      // LP2 trims 200 MEME-pool shares after the last MEME fee booking it participates in.
      { poolId: POOL_MEME, tranche: 0, user: LP2, amount0: 0n, amount1: 1n * WAD, sharesBurned: 200n * WAD, blockNumber: 132_000n, timestamp: 3500, logIndex: 0 },
    ],

    // ---- Vault share ERC-20 transfers (cluster edges + balance moves) ----
    shareTransfers: [
      // LP1 → LP4: moves 500 shares mid-epoch (clusters {LP1, LP4}; neither trades — harmless).
      { poolId: POOL_MEME, tranche: 0, from: LP1, to: LP4, shares: 500n * WAD, blockNumber: 135_000n, timestamp: 4000, logIndex: 5 },
    ],

    // ---- First-funder graph (since genesis) — the wash cluster + distinct honest funders ----
    fundingEdges: [
      { child: WASH, funder: WHALE }, // depth 1
      { child: WASH2, funder: WASH }, // depth 2 → {WHALE, WASH, WASH2}
      { child: T1, funder: CEX1 },
      { child: T2, funder: CEX2 },
      { child: WHALE, funder: CEX3 },
    ],

    unclusterableAddresses: [ROUTER],

    // ---- FeesCollected (revenue = perf fee; net LP fee = fee - perfFee) — per tranche ----
    feesCollected: [
      // MEME t0 booking 1 @1500: LP1 + WHALE held since 1000. rev $1.8, net $16.2.
      { poolId: POOL_MEME, tranche: 0, fee0: 0n, fee1: 6n * 10n ** 15n, perfFee0: 0n, perfFee1: 6n * 10n ** 14n, blockNumber: 110_500n, timestamp: 1500, logIndex: 1 },
      // MEME t0 booking 2 @3000: LP1/WHALE (1500..3000) + LP2 (2000..3000). rev $3.2, net $28.8.
      { poolId: POOL_MEME, tranche: 0, fee0: 2000n * WAD, fee1: 4n * 10n ** 15n, perfFee0: 200n * WAD, perfFee1: 4n * 10n ** 14n, blockNumber: 125_000n, timestamp: 3000, logIndex: 1 },
      // MEME t0 booking 3 @5000: post-withdraw + post-transfer balances. rev $1, net $9.
      { poolId: POOL_MEME, tranche: 0, fee0: 1000n * WAD, fee1: 0n, perfFee0: 100n * WAD, perfFee1: 0n, blockNumber: 140_500n, timestamp: 5000, logIndex: 1 },
      // RWA tranche 0 booking @4000: only LP1. rev $0.4, net $3.6.
      { poolId: POOL_RWA, tranche: 0, fee0: 0n, fee1: 4n * 10n ** 6n, perfFee0: 0n, perfFee1: 4n * 10n ** 5n, blockNumber: 141_000n, timestamp: 4000, logIndex: 1 },
      // RWA tranche 1 booking @4500: only LP2 (Anchor fees stay in Anchor — INV-15). rev $0.36, net $3.24.
      { poolId: POOL_RWA, tranche: 1, fee0: 30n * 10n ** 15n, fee1: 0n, perfFee0: 3n * 10n ** 15n, perfFee1: 0n, blockNumber: 151_000n, timestamp: 4500, logIndex: 1 },
    ],

    // ---- SharePriceCheckpoints (INV-4 monitoring / reconciliation anchors) ----
    checkpoints: [
      { poolId: POOL_MEME, tranche: 0, sharePriceX96: 79228162514264337593543950336n, epochId, blockNumber: 199_000n, timestamp: 6000, logIndex: 0 },
      { poolId: POOL_RWA, tranche: 0, sharePriceX96: 79228162514264337593543950336n, epochId, blockNumber: 199_000n, timestamp: 6000, logIndex: 1 },
      { poolId: POOL_RWA, tranche: 1, sharePriceX96: 79228162514264337593543950336n, epochId, blockNumber: 199_000n, timestamp: 6000, logIndex: 2 },
    ],

    // ---- Pinned pricing per pool (E6 USD) ----
    pools: [
      { poolId: POOL_MEME, token0: { address: MEME, decimals: 18, symbol: "MEME" }, token1: { address: WETH, decimals: 18, symbol: "WETH" }, price0E6: e6(0.01), price1E6: e6(3000) },
      { poolId: POOL_RWA, token0: { address: NVDA, decimals: 18, symbol: "NVDA" }, token1: { address: USDG, decimals: 6, symbol: "USDG" }, price0E6: e6(120), price1E6: e6(1) },
    ],

    // FERA/USD TWAP = $0.05 (E6), pinned (PT-8 pipeline computed it at snapshot build).
    feraTwapE6: e6(0.05),
    prevFeraTwapE6: e6(0.055),

    // cap set high so the β×revenue bound binds globally (representative for early epochs).
    capFeraWei: 10_000_000n * WAD,

    // divMult derived from cluster-collapsed unique traders (no override) — exercises PT-9.
    qualityScoreBps: {},

    // extra absolute cap on the RWA pool BELOW its revenue lock (lock ≈ 12.16 FERA): exercises
    // "per-pool lock is FINAL — the gap is un-emitted, never redistributed to other pools".
    poolCapFeraWei: { [POOL_RWA]: 10n * WAD },

    // boosts: WHALE 2x (self-dealer), LP2 1.5x (honest staker), T1 2x (trader — must be inert
    // on the trader leaf, Decision B). Others default 1x.
    boostX18: { [WHALE]: 2n * WAD, [LP2]: 15n * (WAD / 10n), [T1]: 2n * WAD },

    // no carried opening balances (pools are fresh this epoch)
    openingShares: [],
  };
}
