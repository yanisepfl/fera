// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFeraHook} from "../interfaces/IFeraHook.sol";
import {IFeraVault} from "../interfaces/IFeraVault.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {FeraTypes} from "./FeraTypes.sol";
import {FeraConstants} from "./FeraConstants.sol";
import {FeeLogic} from "./FeeLogic.sol";
import {VaultOps} from "./VaultOps.sol";
import {Band, TrancheState, PoolInfo} from "./VaultTypes.sol";

/// @title VaultMath
/// @notice EIP-170 SIZE-SPLIT of FeraVault (companion to VaultOps). Holds the pure/view strategy
///         math + TWAP/oracle + valuation helpers as PUBLIC library functions, deployed as SEPARATE
///         bytecode and invoked by FeraVault via DELEGATECALL. Behavior is byte-identical to the
///         pre-split inline code (no math/rounding/revert change) — a mechanical relocation to shrink
///         the vault's runtime size. Reuses `VaultOps.Ctx` as the (immutables + vol-clamp) context.
library VaultMath {
    using StateLibrary for IPoolManager;

    // ── Valuation ───────────────────────────────────────────────────────────────────────────

    /// @dev Tranche value in token1 terms at spot (bands + pending + reserves), plus spot context.
    function trancheValue(TrancheState storage tr, VaultOps.Ctx memory c)
        public
        view
        returns (uint256 v, uint160 sqrtPriceX96, int24 tick)
    {
        (sqrtPriceX96, tick,,) = c.pm.getSlot0(c.id);
        uint256 x = tr.pending0 + tr.reserve0;
        uint256 y = tr.pending1 + tr.reserve1;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            if (b.liquidity == 0) continue;
            (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtPriceX96, b.tickLower, b.tickUpper, b.liquidity);
            x += a0;
            y += a1;
        }
        v = _valueInToken1(sqrtPriceX96, x, y);
    }

    function valueInToken1(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1) public pure returns (uint256) {
        return _valueInToken1(sqrtPriceX96, amount0, amount1);
    }

    function _valueInToken1(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        return FullMath.mulDiv(amount0, priceX96, 1 << 96) + amount1;
    }

    /// @dev Token amounts a position of `liquidity` on [lower,upper] holds at `sqrtPriceX96`.
    function _amountsForLiquidity(uint160 sqrtPriceX96, int24 lower, int24 upper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        if (sqrtPriceX96 <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtPriceX96 >= sqrtB) {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liquidity, false);
        }
    }

    /// @dev Subtract a v4 mint-round-up overage from non-banded holdings, reserve first then pending.
    function absorbDepositOverage(TrancheState storage tr, uint256 over0, uint256 over1) public {
        if (over0 != 0) {
            uint256 fromR = over0 < tr.reserve0 ? over0 : tr.reserve0;
            tr.reserve0 -= fromR;
            uint256 rem = over0 - fromR;
            if (rem != 0) tr.pending0 = tr.pending0 > rem ? tr.pending0 - rem : 0;
        }
        if (over1 != 0) {
            uint256 fromR = over1 < tr.reserve1 ? over1 : tr.reserve1;
            tr.reserve1 -= fromR;
            uint256 rem = over1 - fromR;
            if (rem != 0) tr.pending1 = tr.pending1 > rem ? tr.pending1 - rem : 0;
        }
    }

    // ── Vol-adaptive sizing / band geometry ───────────────────────────────────────────────────

    /// @dev width = tierHalf × f(σ), clamped to the governance-set [min,max] multiplier band (§2).
    ///      RWA fixed at 1x (no EWMA-vol signal — recentered toward the oracle instead, §5.1).
    function effectiveHalfWidth(PoolInfo storage p, VaultOps.Ctx memory c, int24 tierHalf)
        public
        view
        returns (int24)
    {
        if (p.regime != FeraTypes.Regime.MEME) return tierHalf;
        (uint256 volEwmaX,,,) = c.hook.memeStateOf(c.id);
        uint256 multBps = FeeLogic.widthMultiplierBps(volEwmaX, c.volMin, c.volMax);
        return int24(int256(FullMath.mulDiv(uint256(uint24(tierHalf)), multBps, FeraConstants.BPS)));
    }

    function bandAround(int24 center, int24 half, int24 spacing) public pure returns (int24 lower, int24 upper) {
        lower = _floorTick(center - half, spacing);
        upper = _ceilTick(center + half, spacing);
        int24 min = TickMath.minUsableTick(spacing);
        int24 max = TickMath.maxUsableTick(spacing);
        if (lower < min) lower = min;
        if (upper > max) upper = max;
    }

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        // slither-disable-next-line weak-prng — tick-spacing alignment (modulo), not randomness.
        int24 r = tick % spacing;
        if (r < 0) r += spacing;
        return tick - r;
    }

    function _ceilTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 fl = _floorTick(tick, spacing);
        return fl == tick ? tick : fl + spacing;
    }

    // ── Base-range / OOR ──────────────────────────────────────────────────────────────────────

    /// @dev The BASE band index (isPrincipal, non-limit). Reverts if the tranche has no base band.
    function _baseIndex(TrancheState storage tr) internal view returns (uint256) {
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            if (tr.bands[i].isPrincipal && !tr.bands[i].isLimit) return i;
        }
        revert IFeraVault.NotBaseLimitPool();
    }

    function baseOutOfRange(TrancheState storage tr, VaultOps.Ctx memory c) public view returns (bool) {
        (, int24 tick,,) = c.pm.getSlot0(c.id);
        Band storage b = tr.bands[_baseIndex(tr)];
        return tick < b.tickLower || tick >= b.tickUpper;
    }

    /// @dev Confirm the OOR is a real move, not a spot spike: the TWAP tick must ALSO be outside the
    ///      base band, and spot must be within the sanity band of the TWAP.
    function requireTwapConfirmedOor(TrancheState storage tr, VaultOps.Ctx memory c) public view {
        (int24 twapTick, bool ready) = _consultTwap(c, FeraConstants.REBALANCE_TWAP_WINDOW_SEC);
        if (!ready) return;
        (uint32 ageSec, bool has) = c.hook.twapObservationAge(c.id);
        if (has && ageSec > FeraConstants.TWAP_MAX_STALENESS_SEC) revert IFeraVault.TwapStale();
        Band storage b = tr.bands[_baseIndex(tr)];
        if (twapTick >= b.tickLower && twapTick < b.tickUpper) revert IFeraVault.OorNotPersistent(); // TWAP in-range ⇒ spike
        if (_twapDeviationBps(c, FeraConstants.REBALANCE_TWAP_WINDOW_SEC) > FeraConstants.REBALANCE_TWAP_SANITY_BPS) {
            revert IFeraVault.TwapOutOfBand();
        }
    }

    // ── TWAP / oracle ───────────────────────────────────────────────────────────────────────

    /// @dev Read the hook TWAP behind a try/catch — a revert degrades to `ready=false` (fail-safe).
    function _consultTwap(VaultOps.Ctx memory c, uint32 window) internal view returns (int24 twapTick, bool ready) {
        try c.hook.consultTwapTick(c.id, window) returns (int24 tt, bool r) {
            return (tt, r);
        } catch {
            return (0, false);
        }
    }

    /// @dev Pool TWAP price (1e18) over `window` from the hook's cumulative-tick oracle; falls back to
    ///      spot when the oracle has no elapsed history yet (fresh pool). REC-9 fail-closed on dormant.
    function _poolTwapPrice(VaultOps.Ctx memory c, uint32 window) internal view returns (uint256) {
        (uint160 sqrtSpot,,,) = c.pm.getSlot0(c.id);
        (int24 twapTick, bool ready) = _consultTwap(c, window);
        uint160 sqrtPriceX96;
        if (ready) {
            (uint32 ageSec, bool has) = c.hook.twapObservationAge(c.id);
            if (has && ageSec > FeraConstants.TWAP_MAX_STALENESS_SEC) revert IFeraVault.TwapStale();
            sqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);
        } else {
            sqrtPriceX96 = sqrtSpot;
        }
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        return FullMath.mulDiv(priceX96, 1e18, 1 << 96);
    }

    /// @dev Pool-TWAP-implied output for `amountIn` at the current TWAP (token1-per-token0, 1e18).
    function twapImpliedOut(VaultOps.Ctx memory c, bool zeroForOne, uint256 amountIn) public view returns (uint256) {
        uint256 price = _poolTwapPrice(c, FeraConstants.REBALANCE_TWAP_WINDOW_SEC);
        return zeroForOne ? FullMath.mulDiv(amountIn, price, 1e18) : FullMath.mulDiv(amountIn, 1e18, price);
    }

    /// @dev |spot − TWAP(window)| in bps of the TWAP.
    function twapDeviationBps(VaultOps.Ctx memory c, uint32 window) public view returns (uint256) {
        return _twapDeviationBps(c, window);
    }

    function _twapDeviationBps(VaultOps.Ctx memory c, uint32 window) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = c.pm.getSlot0(c.id);
        uint256 spot =
            FullMath.mulDiv(FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), 1e18, 1 << 96);
        return _absDeviationBps(spot, _poolTwapPrice(c, window));
    }

    function absDeviationBps(uint256 a, uint256 b) public pure returns (uint256) {
        return _absDeviationBps(a, b);
    }

    function _absDeviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) return type(uint256).max; // undefined baseline ⇒ treat as out-of-band
        uint256 diff = a > b ? a - b : b - a;
        return (diff * FeraConstants.BPS) / b;
    }

    /// @dev Non-reverting Chainlink read: degrades to (0,false) on a stale/absent/malformed feed.
    function tryReadOracle(PoolInfo storage p) public view returns (uint256 price, bool ok) {
        address feed = p.oracleFeed;
        if (feed == address(0)) return (0, false);
        try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) return (0, false);
            if (block.timestamp - updatedAt > FeraConstants.ORACLE_STALENESS_MAX) return (0, false);
            uint8 dec = IAggregatorV3(feed).decimals();
            price = uint256(answer) * (10 ** (18 - dec));
            ok = true;
        } catch {
            return (0, false);
        }
    }

    /// @dev token1-per-token0 price (1e18 basis) from a sqrtPriceX96 — same basis as the oracle price.
    function priceFromSqrt(uint160 sqrtPriceX96) public pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        return FullMath.mulDiv(priceX96, 1e18, 1 << 96);
    }

    /// @dev The tick nearest an oracle price (1e18 basis, token1/token0). Clamped into TickMath's
    ///      legal sqrt-price range so a pathological feed can never make getTickAtSqrtPrice revert.
    function oracleTick(uint256 oraclePrice1e18) public pure returns (int24) {
        uint256 sq = Math.sqrt(FullMath.mulDiv(oraclePrice1e18, uint256(1) << 192, 1e18));
        if (sq < TickMath.MIN_SQRT_PRICE) sq = TickMath.MIN_SQRT_PRICE;
        if (sq > uint256(TickMath.MAX_SQRT_PRICE) - 1) sq = uint256(TickMath.MAX_SQRT_PRICE) - 1;
        return TickMath.getTickAtSqrtPrice(uint160(sq));
    }
}
