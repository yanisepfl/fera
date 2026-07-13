// Reproducible derived metrics (MASTER_SPEC §8: "No off-chain 'projected APY' without a formula
// link"). Every APY/APR the API serves is defined HERE with an explicit integer formula so the
// Frontend can cite it and anyone can reproduce it from indexed on-chain data. Integer/E6 math;
// results are basis points (bigint) unless noted. These are DISPLAY metrics — never posted
// on-chain, never fed to the consensus pipeline.

const BPS = 10_000n;
const YEAR_SECONDS = 365n * 24n * 60n * 60n;

/**
 * feeApr — annualized trailing LP-fee yield vs TVL, in bps.
 *   feeApr_bps = feesUsdE6(window) * (YEAR / window) / tvlUsdE6 * 10000
 * `windowSeconds` is the trailing measurement window (e.g. 7d). Returns 0 if TVL is 0.
 */
export function feeAprBps(feesUsdE6: bigint, tvlUsdE6: bigint, windowSeconds: bigint): bigint {
  if (tvlUsdE6 <= 0n || windowSeconds <= 0n) return 0n;
  const annualizedFees = (feesUsdE6 * YEAR_SECONDS) / windowSeconds;
  return (annualizedFees * BPS) / tvlUsdE6;
}

/**
 * emissionsApr — annualized esFERA emissions value vs TVL, in bps.
 *   emissionsApr_bps = emissionsUsdE6(epoch) * (YEAR / epochSeconds) / tvlUsdE6 * 10000
 * Emissions are valued at the epoch FERA TWAP. Returns 0 if TVL is 0. This is a PROJECTION from
 * the most recent finalized epoch; it is explicitly NOT a promise (see DM-2: usage emissions are
 * a steady-state dividend, not the TVL cold-start lever).
 */
export function emissionsAprBps(
  emissionsUsdE6: bigint,
  tvlUsdE6: bigint,
  epochSeconds: bigint,
): bigint {
  if (tvlUsdE6 <= 0n || epochSeconds <= 0n) return 0n;
  const annualized = (emissionsUsdE6 * YEAR_SECONDS) / epochSeconds;
  return (annualized * BPS) / tvlUsdE6;
}

/**
 * revenueShareApr — annualized staker revenue-share vs staked value, in bps.
 *   apr_bps = revenueToStakersUsdE6(window) * (YEAR / window) / stakedValueUsdE6 * 10000
 */
export function revenueShareAprBps(
  revenueToStakersUsdE6: bigint,
  stakedValueUsdE6: bigint,
  windowSeconds: bigint,
): bigint {
  if (stakedValueUsdE6 <= 0n || windowSeconds <= 0n) return 0n;
  const annualized = (revenueToStakersUsdE6 * YEAR_SECONDS) / windowSeconds;
  return (annualized * BPS) / stakedValueUsdE6;
}

/** FERA wei valued to USD E6 at a FERA/USD TWAP (E6): feraWei * twapE6 / 1e18. */
export function feraWeiToUsdE6(feraWei: bigint, feraTwapE6: bigint): bigint {
  return (feraWei * feraTwapE6) / 10n ** 18n;
}
