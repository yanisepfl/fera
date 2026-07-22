// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFeraShare} from "../interfaces/IFeraShare.sol";
import {IFeraVault} from "../interfaces/IFeraVault.sol";
import {IRevenueDistributor} from "../interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../interfaces/IAnchorStaking.sol";
import {IRebalanceVenue} from "../interfaces/IRebalanceVenue.sol";
import {FeraTypes} from "./FeraTypes.sol";
import {FeraConstants} from "./FeraConstants.sol";
import {VaultOps} from "./VaultOps.sol";
import {VaultMath} from "./VaultMath.sol";
import {VaultFees} from "./VaultFees.sol";
import {TrancheState, PoolInfo} from "./VaultTypes.sol";

/// @title VaultActions
/// @notice EIP-170 SIZE-SPLIT of FeraVault (companion to VaultOps/VaultMath/VaultFees/VaultRwa).
///         Holds the heavy keeper-gated-rebalance / single-coin-redeem entrypoint bodies
///         (`rebalanceBase`, `selfSwap`, `rebalanceViaVenue`, `withdrawSingle`) as PUBLIC library
///         functions, deployed as SEPARATE bytecode and delegatecalled from FeraVault. Behavior —
///         every gate, bound, clock write, reserve-accounting update, and emitted event — is
///         byte-identical to the pre-split inline code. `_requireBaseLimit` (and the venue allowlist
///         check) stay on the vault's thin wrappers; the per-(pool,tranche) clocks are passed as the
///         inner `mapping(uint256 => uint64)` (`lastX[id]`), indexed by `c.t`; `msg.sender` is
///         preserved through the delegatecall so cooldowns/burns/transfers bind the real caller.
library VaultActions {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // Callback action tags — MUST match FeraVault's internal encoding.
    uint8 internal constant CB_REBALANCE_BASE = 6;
    uint8 internal constant CB_SELF_SWAP = 7;
    uint8 internal constant CB_WITHDRAW_SINGLE = 8;

    /// @notice GUARDED wide-BASE recenter (KEEPER-ONLY v3.4, gated on the vault; every bound on-chain). See FeraVault NatSpec.
    function rebalanceBase(
        TrancheState storage tr,
        PoolInfo storage p,
        VaultOps.Ctx memory c,
        bool useSelfSwap,
        IRevenueDistributor rd,
        IAnchorStaking anchor,
        mapping(uint256 => uint64) storage oorSince,
        mapping(uint256 => uint64) storage lastBaseRecenterTs,
        mapping(uint256 => uint64) storage lastRebalanceTs
    ) public {
        // Gate 1 — base OOR now (re-verified, not just at the last poke).
        if (!VaultMath.baseOutOfRange(tr, c)) revert IFeraVault.NotOutOfRange();
        // Gate 2 — OOR sustained ≥ the regime DWELL (anti-whipsaw).
        uint32 dwell = _oorDwell(p);
        uint64 since = oorSince[c.t];
        if (since == 0 || block.timestamp - since < dwell) revert IFeraVault.OorNotPersistent();
        // Gate 3 — ≥ the DEDICATED base-recenter interval since the last BASE recenter (§5.1).
        _requireIntervalSince(lastBaseRecenterTs[c.t], _baseRecenterMinInterval(p));
        // Gate 4 — TWAP-confirmed real move.
        VaultMath.requireTwapConfirmedOor(tr, c);

        VaultFees.checkpoint(tr, p, c, rd, anchor);
        (uint256 vBefore,,) = VaultMath.trancheValue(tr, c);
        // v3 NEW: the IL budget this ONE call's self-swap may spend, in token1-notional terms.
        uint256 ilBudget = FullMath.mulDiv(vBefore, FeraConstants.MAX_IL_BPS_PER_RECENTER, FeraConstants.BPS);
        bool isPartial =
            abi.decode(c.pm.unlock(abi.encode(CB_REBALANCE_BASE, c.id, c.t, abi.encode(useSelfSwap, ilBudget))), (bool));
        (uint256 vAfter,, int24 tick) = VaultMath.trancheValue(tr, c);
        // Gate 5 — execution value conservation (SWAP-SLIPPAGE bound, distinct from the IL cap above).
        if (vAfter * FeraConstants.BPS < vBefore * (FeraConstants.BPS - FeraConstants.MAX_REBALANCE_SLIPPAGE_BPS)) {
            revert IFeraVault.RebalanceSlippage();
        }
        lastBaseRecenterTs[c.t] = uint64(block.timestamp);
        lastRebalanceTs[c.t] = uint64(block.timestamp);
        oorSince[c.t] = 0;
        FeraTypes.StrategyKind kind =
            isPartial ? FeraTypes.StrategyKind.BaseRecenterPartial : FeraTypes.StrategyKind.BaseRecenter;
        emit IFeraVault.StrategyAction(PoolId.unwrap(c.id), uint8(kind), tick, tick, ilBudget, bytes32(0));
    }

    /// @notice Standalone bounded self-swap against the OWN v4 pool (ratio balancing). KEEPER-ONLY
    ///         (gated on the vault). `minInterval` is passed by the vault (the governance-set
    ///         `keeperSwapInterval`, default 0 = no rate-limit for the trusted keeper).
    function selfSwap(
        TrancheState storage tr,
        VaultOps.Ctx memory c,
        bool zeroForOne,
        uint256 amountIn,
        uint32 minInterval,
        mapping(uint256 => uint64) storage lastRebalanceTs
    ) public returns (uint256 amountOut) {
        _requireIntervalSince(lastRebalanceTs[c.t], minInterval);
        uint256 have = zeroForOne ? tr.reserve0 : tr.reserve1;
        if (amountIn == 0 || amountIn > have) revert IFeraVault.Slippage();

        (uint256 nav,,) = VaultMath.trancheValue(tr, c);
        uint256 ilBudget = FullMath.mulDiv(nav, FeraConstants.MAX_IL_BPS_PER_RECENTER, FeraConstants.BPS);
        (uint160 sqrtPriceX96,,,) = c.pm.getSlot0(c.id);
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        uint256 notionalVal = zeroForOne ? FullMath.mulDiv(amountIn, priceX96, 1 << 96) : amountIn;
        if (notionalVal > ilBudget) revert IFeraVault.IlBudgetExceeded();

        amountOut = abi.decode(c.pm.unlock(abi.encode(CB_SELF_SWAP, c.id, c.t, abi.encode(zeroForOne, amountIn))), (uint256));
        lastRebalanceTs[c.t] = uint64(block.timestamp);
        emit IFeraVault.StrategyAction(PoolId.unwrap(c.id), uint8(FeraTypes.StrategyKind.SelfSwap), 0, 0, amountOut, bytes32(0));
    }

    /// @notice Bounded ratio-balancing swap through a whitelisted EXTERNAL venue (KEEPER-ONLY, gated on the vault).
    ///         The venue allowlist check stays on the vault wrapper (its safety boundary).
    function rebalanceViaVenue(
        TrancheState storage tr,
        PoolInfo storage p,
        VaultOps.Ctx memory c,
        address venue,
        bool zeroForOne,
        uint256 amountIn,
        uint32 minInterval,
        mapping(uint256 => uint64) storage lastRebalanceTs
    ) public returns (uint256 amountOut) {
        _requireIntervalSince(lastRebalanceTs[c.t], minInterval);
        uint256 have = zeroForOne ? tr.reserve0 : tr.reserve1;
        if (amountIn == 0 || amountIn > have) revert IFeraVault.Slippage(); // spend only OWN reserve

        // SAME on-chain bound as the self-swap: output ≥ (1 − slippage) × pool-TWAP-implied.
        uint256 minOut = FullMath.mulDiv(
            VaultMath.twapImpliedOut(c, zeroForOne, amountIn),
            FeraConstants.BPS - FeraConstants.MAX_REBALANCE_SLIPPAGE_BPS,
            FeraConstants.BPS
        );
        if (minOut == 0) revert IFeraVault.RebalanceSlippage();
        address tokenIn = Currency.unwrap(zeroForOne ? p.key.currency0 : p.key.currency1);
        address tokenOut = Currency.unwrap(zeroForOne ? p.key.currency1 : p.key.currency0);

        uint256 balInBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(venue, amountIn);
        // Bounded external call. The venue is untrusted: cap the pull via the exact approval, measure
        // BOTH sides by BALANCE DELTA (never trust the return value), reset the approval, re-verify.
        IRebalanceVenue(venue).swapExactIn(tokenIn, tokenOut, amountIn, minOut, address(this));
        IERC20(tokenIn).forceApprove(venue, 0);
        // slither-disable-next-line reentrancy-balance -- reviewed 2026-07-20 (new detector in
        // 0.11.4+, CI pinned to 0.11.3 until re-triaged on a deliberate bump): `amountOut` here is
        // a FRESH post-call balanceOf(), not a stale pre-call snapshot — `balBefore` above is the
        // captured operand, `amountOut`'s own value is read after the external call completes.
        // The caller (FeraVault.rebalanceViaVenue) is `onlyKeeper` + `nonReentrant`, so a reentrant
        // call from `venue` into any state-mutating vault function reverts before it could observe
        // or exploit intermediate state; `venue` itself is team-allowlisted, not attacker-supplied.
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        if (amountOut < minOut) revert IFeraVault.RebalanceSlippage();
        uint256 spentIn = balInBefore - IERC20(tokenIn).balanceOf(address(this));

        if (zeroForOne) {
            tr.reserve0 -= spentIn;
            tr.reserve1 += amountOut;
        } else {
            tr.reserve1 -= spentIn;
            tr.reserve0 += amountOut;
        }
        lastRebalanceTs[c.t] = uint64(block.timestamp);
        emit IFeraVault.StrategyAction(PoolId.unwrap(c.id), uint8(FeraTypes.StrategyKind.VenueSwap), 0, 0, amountOut, bytes32(0));
    }

    /// @notice Redeem `shares` into ONE token (`tokenOut`), swapping the other leg within the bound.
    ///         NEVER pausable (INV-11). `_requireBaseLimit` stays on the vault wrapper (runs first).
    function withdrawSingle(
        TrancheState storage tr,
        PoolInfo storage p,
        VaultOps.Ctx memory c,
        uint256 shares,
        address tokenOut,
        uint256 minOut,
        IRevenueDistributor rd,
        IAnchorStaking anchor,
        mapping(address => uint64) storage depositClock,
        mapping(address => bool) storage cooldownExempt
    ) public returns (uint256 amountOut) {
        // Same cooldown semantics as FeraVault.withdraw (see `cooldownExempt`'s NatSpec / Finding-2
        // hardening): an exempt address still waits its regime's JIT window + margin, never zero.
        // Audit finding (Low): calls the SHARED `VaultMath.exemptWithdrawFloorSec` — the same helper
        // `FeraVault._exemptWithdrawFloorSec` delegates to — instead of reimplementing the regime/
        // JIT-window lookup inline, so this path cannot silently drift from `FeraVault.withdraw`.
        uint32 requiredDelay = cooldownExempt[msg.sender]
            ? VaultMath.exemptWithdrawFloorSec(p.regime)
            : FeraConstants.DEPOSIT_COOLDOWN_SEC;
        if (block.timestamp < depositClock[msg.sender] + requiredDelay) {
            revert IFeraVault.CooldownActive();
        }
        bool wantToken0 = tokenOut == Currency.unwrap(p.key.currency0);
        if (!wantToken0 && tokenOut != Currency.unwrap(p.key.currency1)) revert IFeraVault.BadTier();

        VaultFees.checkpoint(tr, p, c, rd, anchor);
        uint256 totalShares = IFeraShare(tr.share).totalSupply();

        // Pro-rata slice of held (non-banded) balances — round DOWN (R-17). Debited reserve-first.
        uint256 held0 = FullMath.mulDiv(shares, tr.pending0 + tr.reserve0, totalShares);
        uint256 held1 = FullMath.mulDiv(shares, tr.pending1 + tr.reserve1, totalShares);
        _debitHeldPreferReserve(tr, held0, held1);

        IFeraShare(tr.share).burn(msg.sender, shares); // CEI

        amountOut = abi.decode(
            c.pm.unlock(abi.encode(CB_WITHDRAW_SINGLE, c.id, c.t, abi.encode(shares, totalShares, wantToken0, held0, held1))),
            (uint256)
        );
        if (amountOut < minOut) revert IFeraVault.SingleOutTooLow();
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        emit IFeraVault.WithdrawSingle(PoolId.unwrap(c.id), msg.sender, tokenOut, amountOut, shares, c.t);
    }

    // ── local ports of the vault's gate / accounting helpers ─────────────────────────────────

    function _debitHeldPreferReserve(TrancheState storage tr, uint256 amt0, uint256 amt1) internal {
        uint256 r0 = amt0 < tr.reserve0 ? amt0 : tr.reserve0;
        tr.reserve0 -= r0;
        if (amt0 - r0 != 0) tr.pending0 -= (amt0 - r0);
        uint256 r1 = amt1 < tr.reserve1 ? amt1 : tr.reserve1;
        tr.reserve1 -= r1;
        if (amt1 - r1 != 0) tr.pending1 -= (amt1 - r1);
    }

    function _oorDwell(PoolInfo storage p) internal view returns (uint32) {
        return p.regime == FeraTypes.Regime.MEME ? FeraConstants.MEME_OOR_DWELL_SEC : FeraConstants.RWA_OOR_DWELL_SEC;
    }

    function _baseRecenterMinInterval(PoolInfo storage p) internal view returns (uint32) {
        return p.regime == FeraTypes.Regime.MEME
            ? FeraConstants.MEME_BASE_RECENTER_MIN_INTERVAL_SEC
            : FeraConstants.RWA_MIN_REBALANCE_INTERVAL_SEC;
    }

    function _requireIntervalSince(uint64 last, uint32 minInterval) internal view {
        if (last != 0 && block.timestamp - last < minInterval) revert IFeraVault.RebalanceTooSoon();
    }
}
