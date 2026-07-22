// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFeraHook} from "../interfaces/IFeraHook.sol";
import {IFeraVault} from "../interfaces/IFeraVault.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {FeraTypes} from "./FeraTypes.sol";
import {FeraConstants} from "./FeraConstants.sol";
import {FeeLogic} from "./FeeLogic.sol";
import {Band, TierConfig, TrancheState, PoolInfo} from "./VaultTypes.sol";

/// @title VaultOps
/// @notice EIP-170 SIZE-SPLIT of FeraVault. Holds the heavy `unlockCallback` bodies (the v4
///         flash-accounting mutations: modifyLiquidity + settle/take + LiquidityAmounts math + the
///         bounded self-swap) as PUBLIC library functions, deployed as SEPARATE bytecode and invoked
///         by FeraVault via DELEGATECALL. Each function receives the vault's own `storage` structs as
///         references and (because it is a delegatecall) reads/writes the VAULT's storage in place —
///         behavior is byte-identical to the pre-split inline code, only relocated to relieve the
///         vault's runtime size. NO logic/math/rounding/revert change: this is a mechanical move.
/// @dev    `address(this)` inside these functions resolves to the VAULT (delegatecall preserves it),
///         so every settle/take/transfer moves the vault's own tokens exactly as before.
/// @dev    AUDIT NOTE (Informational, v3.5): these `public` functions are DELEGATECALL-ONLY by
///         design (invoked only via FeraVault's linked reference), bypassing every FeraVault
///         modifier (onlyOwner/onlyKeeper/nonReentrant/notPaused/knownTranche/keeperReady) if
///         reached any other way. EMPIRICALLY VERIFIED (test/unit/LibraryDirectCall_PoC.t.sol)
///         narrower than "inert but callable": for a representative `storage`-struct-parameter
///         signature, the library's OWN deployed dispatcher does not even recognize the function's
///         documented selector via a plain external `CALL` — solc's codegen only wires up the
///         delegatecall-style entry point FeraVault's linked reference actually uses, not a live
///         case in the library's own standalone dispatch table. Documented (with the verifying
///         test) so a future auditor doesn't have to rediscover or re-derive this.
library VaultOps {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;

    /// @dev Immutable/scalar vault context threaded to each callback (the vault's immutables + the
    ///      two governance-set vol-width clamp bounds — none live at storage slots the library knows).
    struct Ctx {
        IPoolManager pm;
        IFeraHook hook;
        PoolId id;
        uint8 t;
        uint256 volMin;
        uint256 volMax;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // Public callback entrypoints (one per CB_* tag) — delegatecalled from FeraVault.unlockCallback
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function cbCheckpoint(TrancheState storage tr, PoolInfo storage p, Ctx memory c) public returns (bytes memory) {
        uint256 fee0;
        uint256 fee1;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            if (b.liquidity == 0) continue;
            (uint256 f0, uint256 f1) = _modifyBand(p, c.pm, c.t, b.tickLower, b.tickUpper, 0);
            fee0 += f0;
            fee1 += f1;
        }
        return abi.encode(fee0, fee1);
    }

    function cbFirstDeposit(TrancheState storage tr, PoolInfo storage p, Ctx memory c, bytes memory payload)
        public
        returns (bytes memory)
    {
        (uint256 amount0, uint256 amount1) = abi.decode(payload, (uint256, uint256));
        (uint160 sqrtPriceX96,,,) = c.pm.getSlot0(c.id);

        uint256 sumDL;
        uint256 used0;
        uint256 used1;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(b.tickLower),
                TickMath.getSqrtPriceAtTick(b.tickUpper),
                (amount0 * b.weightBps) / FeraConstants.BPS,
                (amount1 * b.weightBps) / FeraConstants.BPS
            );
            if (dL == 0) continue;
            uint256 bal0Before = p.key.currency0.balanceOfSelf();
            uint256 bal1Before = p.key.currency1.balanceOfSelf();
            _modifyBand(p, c.pm, c.t, b.tickLower, b.tickUpper, int256(uint256(dL)));
            used0 += bal0Before - p.key.currency0.balanceOfSelf();
            used1 += bal1Before - p.key.currency1.balanceOfSelf();
            b.liquidity += dL;
            sumDL += dL;
        }
        return abi.encode(sumDL, used0, used1);
    }

    function cbDeposit(TrancheState storage tr, PoolInfo storage p, Ctx memory c, bytes memory payload)
        public
        returns (bytes memory)
    {
        (uint256 amount0, uint256 amount1) = abi.decode(payload, (uint256, uint256));
        (uint160 sqrtPriceX96,,,) = c.pm.getSlot0(c.id);

        // Ratio-match: replicate the tranche's CURRENT composition. need = amounts for f = 1.
        uint256 need0;
        uint256 need1;
        uint256 sumLBefore;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            sumLBefore += b.liquidity;
            (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtPriceX96, b.tickLower, b.tickUpper, b.liquidity);
            need0 += a0;
            need1 += a1;
        }
        require(sumLBefore != 0, "empty");

        // f (WAD) = the largest uniform fraction of the current book this deposit can fund.
        uint256 f = type(uint256).max;
        if (need0 != 0) f = FullMath.mulDiv(amount0, WAD, need0);
        if (need1 != 0) {
            uint256 f1 = FullMath.mulDiv(amount1, WAD, need1);
            if (f1 < f) f = f1;
        }
        require(f != type(uint256).max && f != 0, "ratio");

        uint256 sumDL;
        uint256 used0;
        uint256 used1;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            // REC-10 robustness: fund each band with fraction `f` of ITS OWN current token amounts and
            // derive the liquidity via getLiquidityForAmounts (rounds the LIQUIDITY down so the v4 mint
            // can never require more than the allocated tokens). Σ allocations ≤ amount_j.
            (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtPriceX96, b.tickLower, b.tickUpper, b.liquidity);
            uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(b.tickLower),
                TickMath.getSqrtPriceAtTick(b.tickUpper),
                FullMath.mulDiv(a0, f, WAD),
                FullMath.mulDiv(a1, f, WAD)
            );
            if (dL == 0) continue;
            uint256 bal0Before = p.key.currency0.balanceOfSelf();
            uint256 bal1Before = p.key.currency1.balanceOfSelf();
            _modifyBand(p, c.pm, c.t, b.tickLower, b.tickUpper, int256(uint256(dL)));
            used0 += bal0Before - p.key.currency0.balanceOfSelf();
            used1 += bal1Before - p.key.currency1.balanceOfSelf();
            b.liquidity += dL;
            sumDL += dL;
        }
        return abi.encode(sumDL, sumLBefore, used0, used1);
    }

    function cbWithdraw(TrancheState storage tr, PoolInfo storage p, Ctx memory c, bytes memory payload)
        public
        returns (bytes memory)
    {
        (uint256 shares, uint256 totalShares, address to) = abi.decode(payload, (uint256, uint256, address));

        uint256 out0;
        uint256 out1;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            uint128 dL = uint128(FullMath.mulDiv(b.liquidity, shares, totalShares)); // floor — R-17
            if (dL == 0) continue;
            (uint256 o0, uint256 o1) = _modifyBand(p, c.pm, c.t, b.tickLower, b.tickUpper, -int256(uint256(dL)));
            out0 += o0;
            out1 += o1;
            b.liquidity -= dL;
        }
        if (out0 != 0) IERC20(Currency.unwrap(p.key.currency0)).safeTransfer(to, out0);
        if (out1 != 0) IERC20(Currency.unwrap(p.key.currency1)).safeTransfer(to, out1);
        return abi.encode(out0, out1);
    }

    /// @dev Pull the IDLE fraction of the base band into reserve (value-conserving band→reserve).
    function cbSkimIdle(TrancheState storage tr, PoolInfo storage p, Ctx memory c, bytes memory payload)
        public
        returns (bytes memory)
    {
        uint256 idleBps = abi.decode(payload, (uint256));
        Band storage b = tr.bands[_baseIndex(tr)];
        uint128 pull = uint128(FullMath.mulDiv(b.liquidity, idleBps, FeraConstants.BPS));
        if (pull != 0) {
            (uint256 o0, uint256 o1) = _modifyBand(p, c.pm, c.t, b.tickLower, b.tickUpper, -int256(uint256(pull)));
            b.liquidity -= pull;
            tr.reserve0 += o0;
            tr.reserve1 += o1;
        }
        return "";
    }

    /// @dev LIMIT-FIRST: collect the (filled) limit band(s) into reserve, then redeploy ONE limit on
    ///      the surplus side near spot from reserve — swap-free. Width vol-adaptive (§2); skew
    ///      inventory-driven (§3, RWA additionally oracle-mean-reversion-biased). Reuses a spent slot.
    function cbRebalanceLimit(TrancheState storage tr, PoolInfo storage p, TierConfig storage cfg, Ctx memory c)
        public
        returns (bytes memory)
    {
        uint256 reuse = type(uint256).max;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage lb = tr.bands[i];
            if (!lb.isLimit) continue;
            if (lb.liquidity != 0) {
                (uint256 o0, uint256 o1) =
                    _modifyBand(p, c.pm, c.t, lb.tickLower, lb.tickUpper, -int256(uint256(lb.liquidity)));
                lb.liquidity = 0;
                tr.reserve0 += o0;
                tr.reserve1 += o1;
            }
            reuse = i;
        }

        (uint160 sqrtPriceX96, int24 tick,,) = c.pm.getSlot0(c.id);
        bool surplus0 = _valueInToken1(sqrtPriceX96, tr.reserve0, 0) >= tr.reserve1;
        uint16 skewBps = _inventorySkewBps(tr, p, sqrtPriceX96, surplus0);
        int24 halfW = _effectiveHalfWidth(p, c, cfg.limitHalfTicks);
        (int24 lower, int24 upper) = _limitTicks(tick, p.key.tickSpacing, halfW, skewBps, surplus0);

        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), tr.reserve0, tr.reserve1
        );
        if (dL != 0) {
            uint256 bal0 = p.key.currency0.balanceOfSelf();
            uint256 bal1 = p.key.currency1.balanceOfSelf();
            _modifyBand(p, c.pm, c.t, lower, upper, int256(uint256(dL)));
            _absorbDepositOverage(tr, bal0 - p.key.currency0.balanceOfSelf(), bal1 - p.key.currency1.balanceOfSelf());
            if (reuse != type(uint256).max) {
                Band storage slot = tr.bands[reuse];
                slot.tickLower = lower;
                slot.tickUpper = upper;
                slot.liquidity = dL;
            } else {
                require(tr.bands.length < FeraConstants.MAX_BANDS_PER_TRANCHE, "bands");
                tr.bands.push(
                    Band({tickLower: lower, tickUpper: upper, liquidity: dL, isPrincipal: false, weightBps: 0, isLimit: true})
                );
            }
        }
        return "";
    }

    /// @dev GUARDED base recenter: close the base into reserve, re-anchor its ticks at spot (vol-
    ///      adaptive width, §2), optionally self-swap the turned-over inventory toward 50/50 — BOUNDED
    ///      by the IL budget (§4: `_balanceReserve` clamps rather than reverting), and re-mint the base.
    function cbRebalanceBase(
        TrancheState storage tr,
        PoolInfo storage p,
        TierConfig storage cfg,
        Ctx memory c,
        bytes memory payload
    ) public returns (bytes memory) {
        (bool selfSwapOn, uint256 ilBudget) = abi.decode(payload, (bool, uint256));
        Band storage b = tr.bands[_baseIndex(tr)];

        if (b.liquidity != 0) {
            (uint256 g0, uint256 g1) = _modifyBand(p, c.pm, c.t, b.tickLower, b.tickUpper, -int256(uint256(b.liquidity)));
            b.liquidity = 0;
            tr.reserve0 += g0;
            tr.reserve1 += g1;
        }

        // Optionally rebalance the (now one-sided) reserve toward 50/50, IL-budget-bounded (§4).
        bool isPartial;
        if (selfSwapOn) {
            (uint160 sqrtPre,,,) = c.pm.getSlot0(c.id);
            isPartial = _balanceReserve(tr, p, c, sqrtPre, ilBudget);
        }

        // RE-READ spot AFTER the self-swap so the base is anchored + SIZED at the TRUE post-swap price.
        (uint160 sqrtPriceX96, int24 tick,,) = c.pm.getSlot0(c.id);
        int24 effHalf = _effectiveHalfWidth(p, c, cfg.baseHalfTicks);
        (int24 lo, int24 hi) = _bandAround(tick, effHalf, p.key.tickSpacing);
        b.tickLower = lo;
        b.tickUpper = hi;

        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), tr.reserve0, tr.reserve1
        );
        if (dL != 0) {
            uint256 bal0 = p.key.currency0.balanceOfSelf();
            uint256 bal1 = p.key.currency1.balanceOfSelf();
            _modifyBand(p, c.pm, c.t, lo, hi, int256(uint256(dL)));
            _absorbDepositOverage(tr, bal0 - p.key.currency0.balanceOfSelf(), bal1 - p.key.currency1.balanceOfSelf());
            b.liquidity = dL;
        }
        return abi.encode(isPartial);
    }

    function cbSelfSwap(TrancheState storage tr, PoolInfo storage p, Ctx memory c, bytes memory payload)
        public
        returns (bytes memory)
    {
        (bool zeroForOne, uint256 amountIn) = abi.decode(payload, (bool, uint256));
        (uint256 spent, uint256 out) = _doSelfSwap(p, c, zeroForOne, amountIn, true);
        if (zeroForOne) {
            tr.reserve0 -= spent;
            tr.reserve1 += out;
        } else {
            tr.reserve1 -= spent;
            tr.reserve0 += out;
        }
        return abi.encode(out);
    }

    /// @dev v3.1 unified fee-routing (§9): bounded self-swap of a NATIVE-side perf fee into the pool's
    ///      quote asset. Reuses `_doSelfSwap` UNCHANGED. Deliberately does NOT touch `tr.reserve0/1`.
    function cbRouteFeeSwap(PoolInfo storage p, Ctx memory c, bytes memory payload) public returns (bytes memory) {
        (bool zeroForOne, uint256 amountIn) = abi.decode(payload, (bool, uint256));
        (, uint256 out) = _doSelfSwap(p, c, zeroForOne, amountIn, true);
        return abi.encode(out);
    }

    /// @dev Single-coin redemption: remove the pro-rata band slice into the Vault, add the pre-debited
    ///      held slice, then self-swap the unwanted leg into `tokenOut` (bounded). Reserve untouched.
    /// @dev Audit finding (High, open-kritt): the two internal conversion swaps below used to pass
    ///      `enforceTwapBound=false` — unlike EVERY other internal swap path in this codebase
    ///      (cbSelfSwap, cbRouteFeeSwap, _balanceReserve, rebalance*), which all pass `true` and are
    ///      capped at MAX_REBALANCE_SLIPPAGE_BPS off a 30-minute TWAP. With `false`, `_doSelfSwap`'s
    ///      own `minOut` collapses to 0 — an unbounded-price-impact swap whose only guard was the
    ///      CALLER-supplied external `minOut` (checked once, in VaultActions.withdrawSingle, AFTER
    ///      this swap already executed against whatever price was current at that instant). Since
    ///      the caller picks their own `minOut`, this protected the WITHDRAWER, not the VAULT: a
    ///      withdrawer could sandwich their own withdrawSingle call (push spot the favorable
    ///      direction, let this conversion execute at the manipulated rate, reverse the push) to
    ///      convert their unwanted leg at an off-market rate, extracting value from the tranche's
    ///      remaining band liquidity — i.e. from the OTHER holders — while setting their own minOut
    ///      low enough to never revert on their own account. Passing `enforceTwapBound=true` closes
    ///      it exactly like every other internal swap: the conversion itself must clear a
    ///      TWAP-anchored bound, independent of whatever `minOut` the caller chose.
    function cbWithdrawSingle(TrancheState storage tr, PoolInfo storage p, Ctx memory c, bytes memory payload)
        public
        returns (bytes memory)
    {
        (uint256 shares, uint256 totalShares, bool wantToken0, uint256 held0, uint256 held1) =
            abi.decode(payload, (uint256, uint256, bool, uint256, uint256));
        uint256 out0 = held0;
        uint256 out1 = held1;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            uint128 dL = uint128(FullMath.mulDiv(b.liquidity, shares, totalShares)); // floor — R-17
            if (dL == 0) continue;
            (uint256 o0, uint256 o1) = _modifyBand(p, c.pm, c.t, b.tickLower, b.tickUpper, -int256(uint256(dL)));
            out0 += o0;
            out1 += o1;
            b.liquidity -= dL;
        }
        uint256 single;
        if (wantToken0) {
            if (out1 != 0) {
                (, uint256 got) = _doSelfSwap(p, c, false, out1, true);
                out0 += got;
            }
            single = out0;
        } else {
            if (out0 != 0) {
                (, uint256 got) = _doSelfSwap(p, c, true, out0, true);
                out1 += got;
            }
            single = out1;
        }
        return abi.encode(single);
    }

    /// @dev v3-hardening (§5.1): RWA in-hours oracle-anchored recenter. Close the base into reserve,
    ///      re-anchor its ticks around the ORACLE tick, redeploy the reserve — SWAP-FREE (no IL).
    function cbRwaOracleRecenter(
        TrancheState storage tr,
        PoolInfo storage p,
        TierConfig storage cfg,
        Ctx memory c,
        bytes memory payload
    ) public returns (bytes memory) {
        int24 oracleTick = abi.decode(payload, (int24));
        Band storage b = tr.bands[_baseIndex(tr)];

        if (b.liquidity != 0) {
            (uint256 g0, uint256 g1) = _modifyBand(p, c.pm, c.t, b.tickLower, b.tickUpper, -int256(uint256(b.liquidity)));
            b.liquidity = 0;
            tr.reserve0 += g0;
            tr.reserve1 += g1;
        }

        int24 effHalf = _effectiveHalfWidth(p, c, cfg.baseHalfTicks); // RWA => tier magnitude (1x)
        (int24 lo, int24 hi) = _bandAround(oracleTick, effHalf, p.key.tickSpacing);
        b.tickLower = lo;
        b.tickUpper = hi;

        (uint160 sqrtPriceX96,,,) = c.pm.getSlot0(c.id);
        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), tr.reserve0, tr.reserve1
        );
        if (dL != 0) {
            uint256 bal0 = p.key.currency0.balanceOfSelf();
            uint256 bal1 = p.key.currency1.balanceOfSelf();
            _modifyBand(p, c.pm, c.t, lo, hi, int256(uint256(dL)));
            _absorbDepositOverage(tr, bal0 - p.key.currency0.balanceOfSelf(), bal1 - p.key.currency1.balanceOfSelf());
            b.liquidity = dL;
        }
        return "";
    }

    /// @dev v3-hardening (§5.1): RWA off-hours / event-window defense. (1) close base into reserve;
    ///      (2) KEEP a `RWA_OFFHOURS_WITHDRAW_FRAC_BPS` fraction in reserve; (3) redeploy the REMAINDER
    ///      over a WIDER band (tier half × `RWA_OFFHOURS_WIDEN_MULT_BPS`) around spot. SWAP-FREE.
    function cbRwaDefend(TrancheState storage tr, PoolInfo storage p, TierConfig storage cfg, Ctx memory c)
        public
        returns (bytes memory)
    {
        Band storage b = tr.bands[_baseIndex(tr)];

        // (1) Close the entire base into reserve; remember the just-closed amounts.
        uint256 got0;
        uint256 got1;
        if (b.liquidity != 0) {
            (got0, got1) = _modifyBand(p, c.pm, c.t, b.tickLower, b.tickUpper, -int256(uint256(b.liquidity)));
            b.liquidity = 0;
            tr.reserve0 += got0;
            tr.reserve1 += got1;
        }

        // (2) PARTIAL WITHDRAW: keep only (BPS − withdrawFrac) of the closed base for redeploy.
        uint256 keepBps = FeraConstants.BPS - FeraConstants.RWA_OFFHOURS_WITHDRAW_FRAC_BPS;
        uint256 deploy0 = FullMath.mulDiv(got0, keepBps, FeraConstants.BPS);
        uint256 deploy1 = FullMath.mulDiv(got1, keepBps, FeraConstants.BPS);
        if (deploy0 > tr.reserve0) deploy0 = tr.reserve0;
        if (deploy1 > tr.reserve1) deploy1 = tr.reserve1;

        // (3) WIDEN: redeploy the remainder over a band twice as wide (RWA_OFFHOURS_WIDEN_MULT_BPS).
        (uint160 sqrtPriceX96, int24 tick,,) = c.pm.getSlot0(c.id);
        int24 baseHalf = cfg.baseHalfTicks;
        int24 widenHalf = int24(
            int256(FullMath.mulDiv(uint256(uint24(baseHalf)), FeraConstants.RWA_OFFHOURS_WIDEN_MULT_BPS, FeraConstants.BPS))
        );
        (int24 lo, int24 hi) = _bandAround(tick, widenHalf, p.key.tickSpacing);
        b.tickLower = lo;
        b.tickUpper = hi;

        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), deploy0, deploy1
        );
        if (dL != 0) {
            uint256 bal0 = p.key.currency0.balanceOfSelf();
            uint256 bal1 = p.key.currency1.balanceOfSelf();
            _modifyBand(p, c.pm, c.t, lo, hi, int256(uint256(dL)));
            _absorbDepositOverage(tr, bal0 - p.key.currency0.balanceOfSelf(), bal1 - p.key.currency1.balanceOfSelf());
            b.liquidity = dL;
        }
        return "";
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // Internal helpers (live in THIS library's bytecode) — ports of the vault's former privates.
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev D-18 tranche-scoped position salt.
    function _salt(uint8 t) internal pure returns (bytes32) {
        return bytes32(uint256(t) + 1);
    }

    /// @dev Modify one band's liquidity and resolve the Vault's currency deltas.
    function _modifyBand(PoolInfo storage p, IPoolManager pm, uint8 t, int24 lower, int24 upper, int256 liquidityDelta)
        internal
        returns (uint256 in0, uint256 in1)
    {
        (BalanceDelta cd,) = pm.modifyLiquidity(
            p.key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: _salt(t)}),
            ""
        );
        in0 = _resolveDelta(pm, p.key.currency0, cd.amount0());
        in1 = _resolveDelta(pm, p.key.currency1, cd.amount1());
    }

    function _resolveDelta(IPoolManager pm, Currency cur, int128 amount) internal returns (uint256 received) {
        if (amount < 0) {
            cur.settle(pm, address(this), uint256(uint128(-amount)), false);
        } else if (amount > 0) {
            cur.take(pm, address(this), uint256(uint128(amount)), false);
            received = uint256(uint128(amount));
        }
    }

    /// @dev Execute a swap against the OWN pool, resolve deltas to the Vault. Does NOT touch reserve
    ///      accounting (callers do). When `enforceTwapBound`, output re-verified against the TWAP.
    function _doSelfSwap(PoolInfo storage p, Ctx memory c, bool zeroForOne, uint256 amountIn, bool enforceTwapBound)
        internal
        returns (uint256 spent, uint256 amountOut)
    {
        if (amountIn == 0) return (0, 0);
        uint256 minOut = enforceTwapBound
            ? FullMath.mulDiv(
                _twapImpliedOut(c, zeroForOne, amountIn),
                FeraConstants.BPS - FeraConstants.MAX_REBALANCE_SLIPPAGE_BPS,
                FeraConstants.BPS
            )
            : 0;
        if (enforceTwapBound && minOut == 0) revert IFeraVault.RebalanceSlippage();
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = c.pm.swap(
            p.key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), ""
        );
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        uint256 r0 = _resolveDelta(c.pm, p.key.currency0, a0);
        uint256 r1 = _resolveDelta(c.pm, p.key.currency1, a1);
        if (zeroForOne) {
            spent = uint256(uint128(-a0));
            amountOut = r1;
        } else {
            spent = uint256(uint128(-a1));
            amountOut = r0;
        }
        if (amountOut < minOut) revert IFeraVault.RebalanceSlippage();
    }

    /// @dev Bounded self-swap of the reserve toward 50/50 value, CAPPED at `ilBudget` (§4).
    function _balanceReserve(TrancheState storage tr, PoolInfo storage p, Ctx memory c, uint160 sqrtPriceX96, uint256 ilBudget)
        internal
        returns (bool capped)
    {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        uint256 val0 = FullMath.mulDiv(tr.reserve0, priceX96, 1 << 96); // reserve0 valued in token1
        if (val0 > tr.reserve1) {
            uint256 idealVal = (val0 - tr.reserve1) / 2;
            uint256 boundedVal = idealVal > ilBudget ? ilBudget : idealVal;
            capped = boundedVal < idealVal;
            uint256 amt0 = FullMath.mulDiv(boundedVal, 1 << 96, priceX96);
            if (amt0 > tr.reserve0) amt0 = tr.reserve0;
            if (amt0 != 0) {
                (uint256 spent, uint256 out) = _doSelfSwap(p, c, true, amt0, true);
                tr.reserve0 -= spent;
                tr.reserve1 += out;
            }
        } else if (tr.reserve1 > val0) {
            uint256 idealVal = (tr.reserve1 - val0) / 2;
            uint256 boundedVal = idealVal > ilBudget ? ilBudget : idealVal;
            capped = boundedVal < idealVal;
            uint256 amt1 = boundedVal > tr.reserve1 ? tr.reserve1 : boundedVal;
            if (amt1 != 0) {
                (uint256 spent, uint256 out) = _doSelfSwap(p, c, false, amt1, true);
                tr.reserve1 -= spent;
                tr.reserve0 += out;
            }
        }
    }

    /// @dev Subtract a v4 mint-round-up overage from non-banded holdings, reserve first then pending.
    function _absorbDepositOverage(TrancheState storage tr, uint256 over0, uint256 over1) internal {
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

    /// @dev The BASE band index (isPrincipal, non-limit). Reverts if the tranche has no base band.
    function _baseIndex(TrancheState storage tr) internal view returns (uint256) {
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            if (tr.bands[i].isPrincipal && !tr.bands[i].isLimit) return i;
        }
        revert IFeraVault.NotBaseLimitPool();
    }

    function _effectiveHalfWidth(PoolInfo storage p, Ctx memory c, int24 tierHalf) internal view returns (int24) {
        if (p.regime != FeraTypes.Regime.MEME) return tierHalf;
        (uint256 volEwmaX,,,) = c.hook.memeStateOf(c.id);
        uint256 multBps = FeeLogic.widthMultiplierBps(volEwmaX, c.volMin, c.volMax);
        return int24(int256(FullMath.mulDiv(uint256(uint24(tierHalf)), multBps, FeraConstants.BPS)));
    }

    function _inventorySkewBps(TrancheState storage tr, PoolInfo storage p, uint160 sqrtPriceX96, bool surplus0)
        internal
        view
        returns (uint16)
    {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        uint256 val0 = FullMath.mulDiv(tr.reserve0, priceX96, 1 << 96);
        uint256 val1 = tr.reserve1;
        uint256 total = val0 + val1;
        if (total == 0) return FeraConstants.LIMIT_SKEW_MIN_BPS;
        uint256 surplusVal = surplus0 ? val0 : val1;
        uint256 rBps = FullMath.mulDiv(surplusVal, FeraConstants.BPS, total);
        if (rBps < FeraConstants.BPS / 2) rBps = FeraConstants.BPS / 2; // floor: surplus is ≥ half by construction
        uint256 invScoreBps = (rBps - FeraConstants.BPS / 2) * 2;
        if (invScoreBps > FeraConstants.BPS) invScoreBps = FeraConstants.BPS;

        uint256 combinedBps = invScoreBps;
        if (p.regime == FeraTypes.Regime.RWA) {
            (uint256 oracle, bool ok) = _tryReadOracle(p);
            if (ok) {
                uint256 spot = FullMath.mulDiv(priceX96, 1e18, 1 << 96);
                if (spot != 0) {
                    int256 maxDev = int256(FeraConstants.ORACLE_BIAS_MAX_DEV_BPS);
                    int256 devBps = (int256(oracle) - int256(spot)) * int256(FeraConstants.BPS) / int256(spot);
                    if (devBps > maxDev) devBps = maxDev;
                    if (devBps < -maxDev) devBps = -maxDev;
                    int256 aligned = surplus0 ? devBps : -devBps;
                    uint256 oracleScoreBps = uint256(((aligned + maxDev) * int256(FeraConstants.BPS)) / (2 * maxDev));
                    uint256 w = FeraConstants.ORACLE_BIAS_WEIGHT_BPS;
                    combinedBps = ((FeraConstants.BPS - w) * invScoreBps + w * oracleScoreBps) / FeraConstants.BPS;
                }
            }
        }

        uint256 span = FeraConstants.LIMIT_SKEW_MAX_BPS - FeraConstants.LIMIT_SKEW_MIN_BPS;
        uint256 skew = FeraConstants.LIMIT_SKEW_MIN_BPS + FullMath.mulDiv(span, combinedBps, FeraConstants.BPS);
        return uint16(skew);
    }

    /// @dev Non-reverting Chainlink read: degrades to (0,false) on a stale/absent/malformed feed.
    function _tryReadOracle(PoolInfo storage p) internal view returns (uint256 price, bool ok) {
        address feed = p.oracleFeed;
        if (feed == address(0)) return (0, false);
        try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) return (0, false);
            if (block.timestamp - updatedAt > FeraConstants.ORACLE_STALENESS_MAX) return (0, false);
            // v3.5 FIX (audit finding, low): a feed with >18 decimals underflowed `18 - dec` and
            // panicked, contradicting this function's "never reverts" contract. Mirrors FeraHook's
            // `_oraclePriceX96` normalization exactly.
            //
            // v3.5.1 FIX (audit finding, medium): `decimals()` is a SEPARATE external call, not
            // covered by the `latestRoundData` try/catch above — Solidity's try/catch only guards the
            // single call named after `try`, so a `decimals()` revert (upgraded/paused proxy, malformed
            // or deliberately-hostile feed implementation) used to propagate straight out of this
            // function instead of degrading to (0,false), breaking the very "never reverts" contract
            // this comment block claims to restore. Wrapping it in its own try/catch closes that gap
            // without needing FeraHook's decimals-caching redesign (`_decimalsOf`/`setOracleFeed`) —
            // this read-only view has no hot swap-path budget to protect, so re-reading decimals()
            // live (safely) is the simpler fix here.
            try IAggregatorV3(feed).decimals() returns (uint8 dec) {
                price = dec <= 18 ? uint256(answer) * (10 ** (18 - dec)) : uint256(answer) / (10 ** (dec - 18));
                ok = true;
            } catch {
                return (0, false);
            }
        } catch {
            return (0, false);
        }
    }

    /// @dev Read the hook TWAP behind a try/catch — a revert degrades to `ready=false` (fail-safe).
    function _consultTwap(Ctx memory c, uint32 window) internal view returns (int24 twapTick, bool ready) {
        try c.hook.consultTwapTick(c.id, window) returns (int24 tt, bool r) {
            return (tt, r);
        } catch {
            return (0, false);
        }
    }

    /// @dev Pool TWAP price (1e18) over `window` seconds from the hook's cumulative-tick oracle;
    ///      falls back to spot when the oracle has no elapsed history yet (fresh pool).
    function _poolTwapPrice(Ctx memory c, uint32 window) internal view returns (uint256) {
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
    function _twapImpliedOut(Ctx memory c, bool zeroForOne, uint256 amountIn) internal view returns (uint256) {
        uint256 price = _poolTwapPrice(c, FeraConstants.REBALANCE_TWAP_WINDOW_SEC);
        return zeroForOne ? FullMath.mulDiv(amountIn, price, 1e18) : FullMath.mulDiv(amountIn, 1e18, price);
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

    function _valueInToken1(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        return FullMath.mulDiv(amount0, priceX96, 1 << 96) + amount1;
    }

    /// @dev Skewed LIMIT ticks near spot: mostly on the surplus side, straddling spot by `inner`.
    function _limitTicks(int24 tick, int24 spacing, int24 halfW, uint16 skewBps, bool surplus0)
        internal
        pure
        returns (int24 lower, int24 upper)
    {
        int24 inner = int24(int256(halfW) * int256(uint256(FeraConstants.BPS - skewBps)) / int256(FeraConstants.BPS));
        if (surplus0) {
            lower = _floorTick(tick - inner, spacing);
            upper = _ceilTick(tick + halfW, spacing);
        } else {
            lower = _floorTick(tick - halfW, spacing);
            upper = _ceilTick(tick + inner, spacing);
        }
        int24 minT = TickMath.minUsableTick(spacing);
        int24 maxT = TickMath.maxUsableTick(spacing);
        if (lower < minT) lower = minT;
        if (upper > maxT) upper = maxT;
        if (upper <= lower) upper = lower + spacing; // degenerate guard
    }

    function _bandAround(int24 center, int24 half, int24 spacing) internal pure returns (int24 lower, int24 upper) {
        lower = _floorTick(center - half, spacing);
        upper = _ceilTick(center + half, spacing);
        int24 min = TickMath.minUsableTick(spacing);
        int24 max = TickMath.maxUsableTick(spacing);
        if (lower < min) lower = min;
        if (upper > max) upper = max;
    }

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        if (r < 0) r += spacing;
        return tick - r;
    }

    function _ceilTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 fl = _floorTick(tick, spacing);
        return fl == tick ? tick : fl + spacing;
    }
}
