// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FeraTypes} from "./FeraTypes.sol";
import {FeraConstants} from "./FeraConstants.sol";

/// @title FeeLogic
/// @notice Pure dynamic-fee computation for the flagless hook. The hook calls `quoteLpFee`
///         inside `beforeSwap` and returns the result via the v4 fee-override mechanism.
/// @dev    INVARIANT DISCIPLINE:
///          - This library NEVER reverts and NEVER returns a protocol fee. It returns only an
///            LP fee (in pips) that the pool charges to LPs' benefit (INV-2).
///          - Every returned fee is clamped into the regime band — the spec forbids reverting a
///            swap for oracle failure or extreme fee; clamp to ceiling / blind-fee instead (§5).
///          - The curve shapes are the verbatim MECHANISM_SPEC math:
///              MEME  §1.5–1.7  fee = clamp(FLOOR + SLOPE·max(0,σ−SIGMA0)) + one-sided sell adder;
///              RWA   §2.2–2.3  base(open/closed) + DEV_SLOPE·|pool−oracle|/oracle, oracle-fail flat.
///            [PROVISIONAL] curve params live in FeraConstants tagged `TODO(spec-freeze)`; they are
///            NON-ZERO conservative launch values so the mechanism actually responds.
library FeeLogic {
    /// @notice Inputs the hook snapshots per swap. Kept as a struct so the ABI to the fee curve
    ///         is stable while Mechanism iterates on which fields it consumes.
    struct FeeInputs {
        FeraTypes.Regime regime;
        // ── MEME ──
        bool isSell; // this swap is the toxic sell side (zeroForOne == sellIsZeroForOne[pool])
        uint256 volEwmaX; // EWMA(r²)·2^16 (Q48.16), tick² units — from the packed MEME state slot
        int256 flowEwmaX; // EWMA(r)·2^16 (Q48.16), signed tick units — net-flow drift
        // ── RWA ──
        bool marketOpen; // underlying market-hours flag (keeper-set, on-chain bounded + schedule)
        uint256 poolPriceX96; // current pool price (sqrtPriceX96²·2^-96) for the deviation overlay
        uint256 oraclePriceX96; // Chainlink feed price in the SAME X96 basis; 0 ⇒ oracle unavailable
    }

    /// @notice Compute the dynamic LP fee (in pips, hundredths of a bip) for one swap.
    /// @dev    Guaranteed within the regime band. Guaranteed non-reverting for ANY input.
    function quoteLpFee(FeeInputs memory in_) internal pure returns (uint24 lpFeePips) {
        if (in_.regime == FeraTypes.Regime.MEME) {
            return _memeFee(in_);
        } else {
            return _rwaFee(in_);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // MEME (MECHANISM_SPEC §1.5–1.7): fee ∝ σ with dead-band, floor, symmetric ceiling; a
    // one-sided sell adder scaled by the vol-normalized flow imbalance, capped at the hard max.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function _memeFee(FeeInputs memory in_) private pure returns (uint24) {
        uint256 floorPips = FeraConstants.MEME_FEE_FLOOR_PIPS;
        uint256 ceilPips = FeraConstants.MEME_FEE_CEIL_PIPS;

        // σ = RMS per-swap tick move ≈ per-swap bps of realized vol. Shared conversion — see
        // `sigmaTicks` (also consumed by FeraVault's vol-adaptive band-width multiplier so both
        // readers of the estimator agree numerically; the estimator itself is NEVER duplicated).
        uint256 sigma = sigmaTicks(in_.volEwmaX);

        // feeBase = clamp(FLOOR + SLOPE·max(0, σ − SIGMA0), FLOOR, CEIL). Dead-band keeps micro-noise at
        // the floor; the ramp is linear in σ (not σ²) — LVR per-trade compensation intuition §1.5. The
        // ceiling is reached at σ = SIGMA0 + (CEIL−FLOOR)/SLOPE; branch there BEFORE the multiply so
        // SLOPE·(σ−SIGMA0) can never overflow for a huge σ.
        uint256 sigmaAtCeil =
            FeraConstants.MEME_FEE_SIGMA0_TICKS + (ceilPips - floorPips) / FeraConstants.MEME_FEE_SLOPE_PIPS_PER_TICK;
        uint256 feeBase;
        if (sigma <= FeraConstants.MEME_FEE_SIGMA0_TICKS) {
            feeBase = floorPips;
        } else if (sigma >= sigmaAtCeil) {
            feeBase = ceilPips;
        } else {
            feeBase = floorPips
                + FeraConstants.MEME_FEE_SLOPE_PIPS_PER_TICK * (sigma - FeraConstants.MEME_FEE_SIGMA0_TICKS);
        }

        // Asymmetric sell-side adder, applied ONLY to the toxic sell direction under one-sided DOWN
        // flow (flowEwmaX < 0). adder = SELL_K · max(0, −imb), imb = flowEwmaX/((σ<<16)+ONE) ∈ ~[−1,1].
        // Computed at full Q16 precision (integer imb would truncate to 0). A pump (flow ≥ 0) or a buy
        // adds nothing — dip-arb heals the pool at the cheaper feeBase (§1.6). Capped at HARD_MAX.
        if (in_.isSell && in_.flowEwmaX < 0) {
            uint256 negFlow = uint256(-in_.flowEwmaX); // |EWMA(r)|·2^16
            uint256 denom = (sigma << 16) + FeraConstants.MEME_ONE; // (σ·2^16)+ONE, never zero
            uint256 adder = (FeraConstants.MEME_SELL_ADDER_K_PIPS * negFlow) / denom;
            // |imb| ≤ 1 by Cauchy–Schwarz, but guard against numeric overshoot before clamp.
            if (adder > FeraConstants.MEME_SELL_ADDER_K_PIPS) adder = FeraConstants.MEME_SELL_ADDER_K_PIPS;
            uint256 feeSell = feeBase + adder;
            uint256 hardMax = FeraConstants.MEME_FEE_HARD_MAX_PIPS;
            return uint24(feeSell > hardMax ? hardMax : feeSell);
        }

        return uint24(feeBase);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // RWA (MECHANISM_SPEC §2.2–2.3): tight open base / widened closed base, a deviation overlay
    // scaling with |pool−oracle|/oracle, clamped to the ceiling; oracle-fail ⇒ flat blind fee.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function _rwaFee(FeeInputs memory in_) private pure returns (uint24) {
        // Oracle unavailable (0 sentinel: reverting feed, non-positive answer, or in-hours staleness):
        // quote the flat blind-pool fee — high, so a down oracle can't be cheaply picked off — while the
        // pool KEEPS QUOTING (§2.2 / §5 / INV-2: never revert a swap for oracle failure).
        if (in_.oraclePriceX96 == 0) {
            return FeraConstants.RWA_ORACLE_FAIL_FEE_PIPS;
        }

        uint256 base = in_.marketOpen ? FeraConstants.RWA_FEE_INHOURS_PIPS : FeraConstants.RWA_FEE_OFFHOURS_PIPS;

        // devBps = |pool−oracle|/oracle in bps; overlay = DEV_SLOPE (20) pips per bp of deviation.
        uint256 deviationBps = _absDeviationBps(in_.poolPriceX96, in_.oraclePriceX96);
        uint256 overlay = deviationBps * FeraConstants.RWA_DEV_SLOPE_PIPS_PER_BP;

        // clamp(base + overlay, base, CEIL). Lower bound is `base` (not the open base) so the closed
        // base is never clamped away; overlay ≥ 0 makes the lower clamp a formality but explicit.
        return _clamp(base + overlay, base, FeraConstants.RWA_FEE_CEIL_PIPS);
    }

    /// @notice |a−b| / b in bps. `b != 0` guaranteed by the oracle-fail branch above.
    function _absDeviationBps(uint256 a, uint256 b) private pure returns (uint256) {
        uint256 diff = a > b ? a - b : b - a;
        return (diff * FeraConstants.BPS) / b;
    }

    /// @notice Integer (floor) sqrt — OZ-style bit-length seed + fixed Newton steps. Overflow-safe for
    ///         ANY input incl. type(uint256).max (uses `x / r`, never `x + 1`), so §5/INV-2 "never
    ///         reverts" holds. Used for σ = √(EWMA(r²)).
    function _isqrt(uint256 x) private pure returns (uint256) {
        if (x == 0) return 0;
        uint256 r = 1;
        uint256 xx = x;
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x4) {
            r <<= 1;
        }
        // Newton: 7 iterations converge for the full uint256 range.
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        uint256 r1 = x / r;
        return r < r1 ? r : r1;
    }

    /// @notice Clamp `x` into [lo, hi], returning a uint24 (fits: hi ≤ MAX_LP_FEE_PIPS).
    function _clamp(uint256 x, uint256 lo, uint256 hi) private pure returns (uint24) {
        if (x < lo) x = lo;
        if (x > hi) x = hi;
        return uint24(x);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // v3 (contracts/VAULT_STRATEGY_V3.md §2) — shared EWMA-state conversion. `sigmaTicks` is the
    // ONE place `volEwmaX` (EWMA(r²)·2^16, the packed MEME state slot) is converted to a per-swap
    // RMS tick move σ; both the dynamic-fee curve (`_memeFee` above) and FeraVault's vol-adaptive
    // band-width multiplier (`widthMultiplierBps`) call it, so a single estimator has exactly ONE
    // reader-side interpretation — the Vault does not (and must not) re-derive vol independently.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// @notice σ = √(EWMA(r²)) from the packed Q16 state. Never reverts (see `_isqrt`).
    function sigmaTicks(uint256 volEwmaX) internal pure returns (uint256) {
        // isqrt(volEwmaX) = √(EWMA(r²))·2^8 ⇒ (>>8) = √(EWMA(r²)) = σ.
        return _isqrt(volEwmaX) >> 8;
    }

    /// @notice Vol-adaptive band-width multiplier (bps of 1x) from the SAME EWMA(r²) the dynamic fee
    ///         reads — wider bands for a volatile pool, tighter for a calm one. A linear ramp with a
    ///         dead-band (mirrors the fee curve's shape for calibration consistency — see
    ///         FeraConstants.VOL_WIDTH_MULT_SIGMA0_TICKS/_SLOPE_BPS_PER_TICK), clamped to the CALLER-
    ///         supplied [minBps, maxBps] so the result can never degenerate to zero width nor blow out
    ///         unbounded — those bounds are governance-set but themselves immutable-legal-range-
    ///         bounded in `FeraVault` (the Gamma lesson). Pure; never reverts.
    /// @param volEwmaX the packed EWMA(r²)·2^16 read from `IFeraHook.memeStateOf` — NOT re-estimated.
    /// @param minBps   floor of the governance-set clamp band (bps of 1x).
    /// @param maxBps   ceiling of the governance-set clamp band (bps of 1x); MUST be ≥ minBps.
    function widthMultiplierBps(uint256 volEwmaX, uint256 minBps, uint256 maxBps)
        internal
        pure
        returns (uint256 multBps)
    {
        uint256 sigma = sigmaTicks(volEwmaX);
        uint256 sigma0 = FeraConstants.VOL_WIDTH_MULT_SIGMA0_TICKS;
        if (sigma <= sigma0) return minBps;
        uint256 raw = minBps + FeraConstants.VOL_WIDTH_MULT_SLOPE_BPS_PER_TICK * (sigma - sigma0);
        return raw > maxBps ? maxBps : raw;
    }
}
