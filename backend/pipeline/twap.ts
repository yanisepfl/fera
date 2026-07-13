// FERA/USD valuation TWAP — PT-8 FROZEN (MASTER_SPEC v0.6 §7 + PARAMS.md §E + MECHANISM_SPEC
// §4.3). CONSENSUS-CRITICAL: part of the reproducibility bundle's scriptVersionHash; the
// resulting value is PINNED into the epoch snapshot (`feraTwapE6`) at snapshot build.
//
// Frozen definition:
//   window        : trailing FERA_TWAP_WINDOW_SEC = 604800 (7 d = one epoch)
//   per-obs clamp : each observation is clamped to within ±FERA_TWAP_CLAMP_BPS_PER_OBS (200 =
//                   ±2%) of the previous ACCEPTED value — the deterministic integer realization
//                   of the "±200bp per block-observation log-return clamp" (multiplicative
//                   bounds; the clamped value carries forward, so a single-block flash print
//                   can never move the mean).
//   drop-clamp    : the valuation TWAP for epoch e is floored at
//                   (1 − FERA_TWAP_EPOCH_MAX_DROP_BPS) × twap(e−1) = 70% of the previous
//                   epoch's — sustained suppression over-emits at most δ/(1−δ) ≈ 43% of one
//                   epoch's E even if suppression were free.
//   cardinality   : fewer than FERA_TWAP_MIN_CARDINALITY = 5000 observations in the window ⇒
//                   FAIL-STATIC to the previous epoch's TWAP (a freshly-seeded or thinned pool
//                   can never set the valuation). Same for an empty window.
//   asymmetry     : every clamp errs toward OVER-valuing FERA ⇒ UNDER-emission — always the
//                   safe direction (a genuine crash slows emissions; it never inflates them).
//
// Integer/bigint only. Observations are the FERA/USDG canonical-pool swap prints (E6).

import type { PriceE6 } from "../src/lib/prices";
import {
  FERA_TWAP_WINDOW_SEC,
  FERA_TWAP_CLAMP_BPS_PER_OBS,
  FERA_TWAP_EPOCH_MAX_DROP_BPS,
  FERA_TWAP_MIN_CARDINALITY,
} from "./config";

export interface PriceObservation {
  timestamp: number; // unix seconds
  priceE6: PriceE6;
}

export interface TwapParams {
  windowEnd: number; // exclusive unix seconds (epoch close)
  windowStart?: number; // inclusive; default windowEnd − FERA_TWAP_WINDOW_SEC
  clampBpsPerObs?: number; // default FERA_TWAP_CLAMP_BPS_PER_OBS (PT-8 frozen)
  epochMaxDropBps?: number; // default FERA_TWAP_EPOCH_MAX_DROP_BPS (PT-8 frozen)
  minCardinality?: number; // default FERA_TWAP_MIN_CARDINALITY (PT-8 frozen)
  // previous epoch's accepted valuation TWAP (E6): the drop-clamp floor AND the fail-static
  // fallback. Undefined only for epoch 0 (no prior epoch) — then fail-static throws instead
  // (there is nothing safe to fall back to; the snapshot builder must supply a genesis value).
  prevEpochTwapE6?: PriceE6;
}

export interface TwapResult {
  twapE6: PriceE6;
  // provenance for the reproducibility bundle
  source: "window" | "fail-static-cardinality" | "fail-static-empty";
  observations: number;
  clampedObservations: number; // how many obs hit the per-obs clamp (diagnostic)
  dropClamped: boolean; // whether the epoch drop-clamp floor bound
}

const BPS = 10_000n;

/**
 * PT-8 hardened FERA TWAP over [windowStart, windowEnd). Observations must be sorted by
 * timestamp ascending (ties broken upstream by (block, logIndex) — the snapshot builder
 * guarantees a strict order). Deterministic integer math only.
 */
export function feraTwapE6(obs: PriceObservation[], p: TwapParams): TwapResult {
  const windowStart = p.windowStart ?? p.windowEnd - FERA_TWAP_WINDOW_SEC;
  const clampBps = BigInt(p.clampBpsPerObs ?? FERA_TWAP_CLAMP_BPS_PER_OBS);
  const maxDropBps = BigInt(p.epochMaxDropBps ?? FERA_TWAP_EPOCH_MAX_DROP_BPS);
  const minCardinality = p.minCardinality ?? FERA_TWAP_MIN_CARDINALITY;

  const pts = obs
    .filter((o) => o.timestamp >= windowStart && o.timestamp < p.windowEnd)
    .sort((a, b) => a.timestamp - b.timestamp);

  const failStatic = (source: TwapResult["source"]): TwapResult => {
    if (p.prevEpochTwapE6 === undefined || p.prevEpochTwapE6 <= 0n) {
      throw new Error(
        `twap: ${source} with no previous epoch TWAP to fail static to (epoch 0 needs a genesis value)`,
      );
    }
    return {
      twapE6: p.prevEpochTwapE6,
      source,
      observations: pts.length,
      clampedObservations: 0,
      dropClamped: false,
    };
  };

  if (pts.length === 0) return failStatic("fail-static-empty");
  if (pts.length < minCardinality) return failStatic("fail-static-cardinality");

  // per-observation clamp vs previous ACCEPTED value (the clamped value carries forward)
  let prevAccepted: bigint | null = null;
  let clampedCount = 0;
  const clamp = (price: bigint): bigint => {
    if (prevAccepted === null) return price;
    const up = (prevAccepted * (BPS + clampBps)) / BPS;
    const down = (prevAccepted * (BPS - clampBps)) / BPS;
    if (price > up) {
      clampedCount++;
      return up;
    }
    if (price < down) {
      clampedCount++;
      return down;
    }
    return price;
  };

  // time-weighted mean of the clamped step function over the window
  let weightedSum = 0n;
  let totalDt = 0n;
  for (let i = 0; i < pts.length; i++) {
    const o = pts[i]!;
    const accepted = clamp(o.priceE6);
    prevAccepted = accepted;
    const segStart = Math.max(o.timestamp, windowStart);
    const segEnd = i + 1 < pts.length ? Math.min(pts[i + 1]!.timestamp, p.windowEnd) : p.windowEnd;
    if (segEnd <= segStart) continue;
    const dt = BigInt(segEnd - segStart);
    weightedSum += accepted * dt;
    totalDt += dt;
  }
  if (totalDt === 0n) return failStatic("fail-static-empty");
  let twap = weightedSum / totalDt;

  // epoch drop-clamp: twap(e) ≥ (1 − maxDrop) × twap(e−1)
  let dropClamped = false;
  if (p.prevEpochTwapE6 !== undefined && p.prevEpochTwapE6 > 0n) {
    const floor = (p.prevEpochTwapE6 * (BPS - maxDropBps)) / BPS;
    if (twap < floor) {
      twap = floor;
      dropClamped = true;
    }
  }

  return {
    twapE6: twap,
    source: "window",
    observations: pts.length,
    clampedObservations: clampedCount,
    dropClamped,
  };
}
