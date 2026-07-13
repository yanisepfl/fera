// Fee valuation helpers.
//
// D-3 (MASTER_SPEC §13): the `Swap` event carries `feeAmount` in the INPUT token (token0 when
// zeroForOne, token1 otherwise). Backend converts to USD via Chainlink feed prices. This
// module implements that conversion using INTEGER fixed-point only — no floating point on any
// value that feeds the consensus-critical emissions pipeline (§9). USD is carried as `E6`
// (micro-dollars, 1e6 = $1). FERA/USD TWAP is carried as `E6` as well.
//
// Determinism rule: every price used by pipeline/ MUST come from the frozen epoch input
// snapshot (a price series pinned to block/timestamp), never a live RPC call. Live conversion
// (api/, ops/) MAY read live feeds because those numbers are display-only and never posted.

export type PriceE6 = bigint; // token price in USD, scaled by 1e6

export interface TokenMeta {
  address: `0x${string}`;
  decimals: number;
  symbol: string;
}

/**
 * Value a raw token amount in micro-dollars (E6), deterministic integer math.
 *   valueE6 = amountRaw * priceE6 / 10^decimals
 * Floors. Safe for weights (relative precision preserved). Never used to mint.
 */
export function valueE6(amountRaw: bigint, priceE6: PriceE6, decimals: number): bigint {
  if (amountRaw < 0n) amountRaw = -amountRaw;
  return (amountRaw * priceE6) / 10n ** BigInt(decimals);
}

/**
 * The input token of a swap, per pool convention (§6 Swap): zeroForOne => token0 is spent.
 */
export function inputToken(zeroForOne: boolean, token0: `0x${string}`, token1: `0x${string}`) {
  return zeroForOne ? token0 : token1;
}

/**
 * Convert a USD value (E6) into FERA wei (18 dec) at a FERA/USD TWAP (E6).
 *   feraWei = valueE6 * 1e18 / feraTwapE6
 */
export function usdE6ToFeraWei(usdE6: bigint, feraTwapE6: PriceE6): bigint {
  if (feraTwapE6 <= 0n) throw new Error("prices: feraTwapE6 must be > 0");
  return (usdE6 * 10n ** 18n) / feraTwapE6;
}

/**
 * Chainlink answer (int256, `decimals` dp) -> PriceE6. Used by api/ + ops/ live paths and by
 * the snapshot builder. Reverts on non-positive answers (clamp upstream).
 */
export function chainlinkToPriceE6(answer: bigint, feedDecimals: number): PriceE6 {
  if (answer <= 0n) throw new Error("prices: non-positive chainlink answer");
  const d = BigInt(feedDecimals);
  if (feedDecimals >= 6) return answer / 10n ** (d - 6n);
  return answer * 10n ** (6n - d);
}
