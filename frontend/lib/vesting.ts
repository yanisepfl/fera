/**
 * esFERA vesting + instant-exit math. Mirrors MASTER_SPEC §0/§7 and INV-9:
 *   - esFERA vests ~6 months linearly to FERA 1:1.
 *   - Instant exit takes a 50% HAIRCUT; the forfeited half is split exactly
 *     1/3 burn / 1/3 stakers / 1/3 RevenueDistributor (conserves value, INV-9).
 * The UI uses these to make forfeiture impossible to miss before confirmation.
 */

export const HAIRCUT_BPS = 5000; // 50%
export const VEST_DAYS = 182; // ~6 months

export interface HaircutBreakdown {
  /** esFERA being instant-exited */
  input: number;
  /** FERA received now */
  received: number;
  /** total esFERA forfeited (the haircut) */
  forfeited: number;
  /** forfeiture routing (INV-9), each = forfeited / 3 */
  toBurn: number;
  toStakers: number;
  toRevenue: number;
  /** what you'd get if you instead waited the full vest (1:1) */
  ifWaited: number;
}

export function haircut(inputEsFera: number): HaircutBreakdown {
  const input = Math.max(0, inputEsFera);
  const received = (input * (10_000 - HAIRCUT_BPS)) / 10_000;
  const forfeited = input - received;
  const third = forfeited / 3;
  return {
    input,
    received,
    forfeited,
    toBurn: third,
    toStakers: third,
    toRevenue: third,
    ifWaited: input,
  };
}

export interface VestProgress {
  /** 0..1 fraction of the grant that has linearly vested */
  fraction: number;
  /** FERA vested so far (before subtracting already-claimed) */
  vested: number;
  /** FERA claimable right now (vested − claimed), no haircut */
  claimable: number;
  /** esFERA still locked (would take the haircut if instant-exited) */
  unvested: number;
  /** unix seconds remaining until fully vested */
  secondsLeft: number;
}

export function vestProgress(
  amount: number,
  startTs: number,
  endTs: number,
  claimed: number,
  nowSec = Math.floor(Date.now() / 1000)
): VestProgress {
  const total = Math.max(1, endTs - startTs);
  const fraction = Math.max(0, Math.min(1, (nowSec - startTs) / total));
  const vested = amount * fraction;
  const claimable = Math.max(0, vested - claimed);
  const unvested = amount - vested;
  return {
    fraction,
    vested,
    claimable,
    unvested,
    secondsLeft: Math.max(0, endTs - nowSec),
  };
}
