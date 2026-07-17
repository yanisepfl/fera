// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFeraShare} from "../interfaces/IFeraShare.sol";
import {IFeraVault} from "../interfaces/IFeraVault.sol";
import {IRevenueDistributor} from "../interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../interfaces/IAnchorStaking.sol";
import {FeraConstants} from "./FeraConstants.sol";
import {VaultOps} from "./VaultOps.sol";
import {VaultFees} from "./VaultFees.sol";
import {WithdrawRequest, TrancheState, PoolInfo} from "./VaultTypes.sol";

/// @title VaultQueue
/// @notice EIP-170 SIZE-SPLIT of FeraVault (companion to VaultOps/VaultActions/VaultMath/VaultFees/
///         VaultRwa). Holds the heavy bodies of the UNIVERSAL 24h async-redemption queue
///         (ERC-7540-style): `request` (escrow + record), `claim` (settle in-kind pro-rata + burn),
///         and `returnEscrow` (guardian-flag → owner-return). PUBLIC functions, deployed as SEPARATE
///         bytecode and DELEGATECALLED from FeraVault — so `address(this)` is the VAULT, `msg.sender`
///         is the real caller, and every storage ref (the request mapping, the tranche/pool structs)
///         reads/writes the vault's own state in place. The request-mapping + `reqId` counter +
///         guardian STATE stay on the vault; thin wrappers there do access control + pause and
///         delegate here.
///
/// @dev    THE SOLVENCY INVARIANT (Σ pending+live claims ≤ vault holdings, at ALL times) is achieved
///         BY CONSTRUCTION, not by bookkeeping:
///           1. ESCROW, don't lock a number. `request` TRANSFERS the caller's shares into the vault's
///              custody (they are NOT burned and NO token amount is snapshotted) — the shares stay in
///              `totalSupply`, so the requester stays proportionally invested through the delay.
///           2. SETTLE at CLAIM, pro-rata of CURRENT holdings. `claim` pays
///              `mulDiv(currentHolding, escrowedShares, currentTotalSupply)` (floor) via the EXACT
///              existing `CB_WITHDRAW` / `CB_WITHDRAW_SINGLE` unlock primitives — a fraction of what
///              ACTUALLY exists right now, so it can never remove more than its share no matter what
///              happened during the delay (fees, rebalances, price moves).
///           3. BURN at CLAIM. The escrowed shares are burned exactly as the assets leave, so
///              `totalSupply` and holdings drop together ⇒ pricePerShare-neutral, other holders are
///              never diluted or shorted.
library VaultQueue {
    using SafeERC20 for IERC20;

    // Callback action tags — MUST match FeraVault's / VaultOps' internal encoding.
    uint8 internal constant CB_WITHDRAW = 3;
    uint8 internal constant CB_WITHDRAW_SINGLE = 8;

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // REQUEST — escrow the caller's shares into the vault, record the pending redemption.
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Escrow `shares` from `msg.sender` and record a redemption unlocking after the universal
    ///         delay. Gated by the depositor's own 1h DEPOSIT_COOLDOWN (the REQUEST is gated, not the
    ///         claim — Veda anti-JIT, PARAMS §D2). `single=false` ⇒ in-kind exit bounded by
    ///         (minAmount0,minAmount1); `single=true` ⇒ single-token exit into `tokenOut` bounded by
    ///         `minOut`, settled within the SAME on-chain TWAP slippage bound at claim time.
    /// @dev    ESCROW vs the transferLock (anti-JIT): the cooldown gate below is satisfied EXACTLY when
    ///         the sender's share `transferLockUntil` (which the vault set to lastDeposit+COOLDOWN on
    ///         deposit, and which is extend-only) has elapsed — so the escrow `transferFrom` into the
    ///         vault is ALWAYS permitted; the lock can never strand a matured request. (A holder who
    ///         acquired shares by transfer, never depositing, has depositClock==0 and no lock at all.)
    function request(
        mapping(uint256 => WithdrawRequest) storage requests,
        TrancheState storage tr,
        PoolInfo storage p,
        mapping(address => uint64) storage depositClock,
        uint256 reqId,
        PoolId id,
        uint8 t,
        uint256 shares,
        bool single,
        address tokenOut,
        uint256 minOut,
        uint256 minAmount0,
        uint256 minAmount1
    ) public {
        if (shares == 0) revert IFeraVault.ZeroShares();
        // 1h deposit cooldown gates the REQUEST (kills flash-loan / same-block round trips at entry).
        if (block.timestamp < uint256(depositClock[msg.sender]) + FeraConstants.DEPOSIT_COOLDOWN_SEC) {
            revert IFeraVault.CooldownActive();
        }
        if (single) {
            // Validate tokenOut up-front (mirrors the pre-queue withdrawSingle guard) so a request can
            // never be recorded with an un-settleable target.
            bool wantToken0 = tokenOut == Currency.unwrap(p.key.currency0);
            if (!wantToken0 && tokenOut != Currency.unwrap(p.key.currency1)) revert IFeraVault.BadTier();
        }

        // ESCROW: pull the shares into the vault's own custody. They REMAIN in totalSupply (not burned)
        // ⇒ the requester stays proportionally invested for the full delay; only the EXIT is delayed.
        IFeraShare(tr.share).transferFrom(msg.sender, address(this), shares);

        uint64 unlockTime = uint64(block.timestamp) + FeraConstants.WITHDRAW_DELAY_SEC;
        requests[reqId] = WithdrawRequest({
            owner: msg.sender,
            id: id,
            t: t,
            shares: shares,
            unlockTime: unlockTime,
            single: single,
            tokenOut: tokenOut,
            minOut: minOut,
            minAmount0: minAmount0,
            minAmount1: minAmount1,
            flagged: false,
            settled: false
        });
        emit IFeraVault.WithdrawRequested(reqId, msg.sender, PoolId.unwrap(id), t, shares, unlockTime);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // CLAIM — settle a matured request IN-KIND PRO-RATA of CURRENT holdings, then burn the escrow.
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Settle a matured, un-flagged, un-paused request. PERMISSIONLESS caller — the payout
    ///         ALWAYS goes to `request.owner` (a third party can only PUSH a matured claim to the
    ///         owner, never redirect it). Reuses the EXACT existing pro-rata unlock primitives against
    ///         the CURRENT totalSupply/holdings, so it is solvent regardless of intervening activity.
    /// @return amount0 token0 paid to the owner (for a single-token claim: the single leg iff
    ///         tokenOut==token0, else 0)
    /// @return amount1 token1 paid to the owner (for a single-token claim: the single leg iff
    ///         tokenOut==token1, else 0)
    function claim(
        mapping(uint256 => WithdrawRequest) storage requests,
        TrancheState storage tr,
        PoolInfo storage p,
        VaultOps.Ctx memory c,
        uint256 reqId,
        IRevenueDistributor rd,
        IAnchorStaking anchor
    ) public returns (uint256 amount0, uint256 amount1) {
        WithdrawRequest storage r = requests[reqId];
        address owner = r.owner;
        if (owner == address(0)) revert IFeraVault.UnknownRequest();
        if (r.settled) revert IFeraVault.RequestSettled();
        if (r.flagged) revert IFeraVault.RequestFlagged();
        if (block.timestamp < r.unlockTime) revert IFeraVault.RequestNotMatured();
        // PAUSE gate (DELIBERATE: this changes the legacy "withdrawals never pausable" rule — see the
        // FeraVault claimWithdraw NatSpec). During a confirmed exploit the vault-wide pause freezes ALL
        // claims so an attacker's queued claims cannot settle; the 24h delay is what makes this
        // circuit-breaker effective. requestWithdraw stays open; deposits remain paused as before.
        if (p.paused) revert IFeraVault.ClaimsPaused();

        // EFFECTS FIRST (CEI): mark settled before any external interaction so a token callback can
        // never re-enter to double-settle (the vault wrapper is also nonReentrant — belt & suspenders).
        r.settled = true;
        uint256 shares = r.shares;

        // D-18: realize fees so the exiting shares are paid at a fee-checkpointed NAV. Checkpoint mints/
        // burns NO shares (it only moves realized fees into pending), so totalSupply is stable here.
        VaultFees.checkpoint(tr, p, c, rd, anchor);
        // CURRENT totalSupply — STILL INCLUDES the escrowed `shares` (they burn below). The pro-rata
        // denominator is therefore honest: `shares / totalShares` is this claim's true live fraction.
        uint256 totalShares = IFeraShare(tr.share).totalSupply();

        if (r.single) {
            amount0 = _settleSingle(tr, p, c, r, owner, shares, totalShares);
            amount1 = 0;
            if (r.tokenOut != Currency.unwrap(p.key.currency0)) {
                (amount0, amount1) = (0, amount0); // single leg is token1
            }
        } else {
            (amount0, amount1) = _settleInKind(tr, p, c, owner, shares, totalShares, r.minAmount0, r.minAmount1);
        }
        emit IFeraVault.WithdrawClaimed(reqId, owner, amount0, amount1);
    }

    /// @dev In-kind settlement — the pre-queue `withdraw` body verbatim, but over ESCROWED shares
    ///      (burned from the vault's own custody) paid to `owner`. All rounding is DOWN, against the
    ///      withdrawer (R-17): dust stays with remaining holders, so a claim NEVER over-extracts.
    function _settleInKind(
        TrancheState storage tr,
        PoolInfo storage p,
        VaultOps.Ctx memory c,
        address owner,
        uint256 shares,
        uint256 totalShares,
        uint256 minAmount0,
        uint256 minAmount1
    ) internal returns (uint256 amount0, uint256 amount1) {
        // Pro-rata slice of held (non-banded) balances — floor, decremented in place.
        uint256 dPending0 = FullMath.mulDiv(shares, tr.pending0, totalShares);
        uint256 dPending1 = FullMath.mulDiv(shares, tr.pending1, totalShares);
        uint256 dReserve0 = FullMath.mulDiv(shares, tr.reserve0, totalShares);
        uint256 dReserve1 = FullMath.mulDiv(shares, tr.reserve1, totalShares);
        tr.pending0 -= dPending0;
        tr.pending1 -= dPending1;
        tr.reserve0 -= dReserve0;
        tr.reserve1 -= dReserve1;
        uint256 heldOut0 = dPending0 + dReserve0;
        uint256 heldOut1 = dPending1 + dReserve1;

        // Burn the ESCROWED shares (from the vault's custody), then realize the banded slice.
        IFeraShare(tr.share).burn(address(this), shares);
        (uint256 out0, uint256 out1) = abi.decode(
            c.pm.unlock(abi.encode(CB_WITHDRAW, c.id, c.t, abi.encode(shares, totalShares, owner))), (uint256, uint256)
        );

        amount0 = out0 + heldOut0;
        amount1 = out1 + heldOut1;
        if (heldOut0 != 0) IERC20(Currency.unwrap(p.key.currency0)).safeTransfer(owner, heldOut0);
        if (heldOut1 != 0) IERC20(Currency.unwrap(p.key.currency1)).safeTransfer(owner, heldOut1);
        if (amount0 < minAmount0 || amount1 < minAmount1) revert IFeraVault.Slippage();
    }

    /// @dev Single-token settlement — the pre-queue `withdrawSingle` body verbatim, but over ESCROWED
    ///      shares (burned from custody) paid to `owner`. Takes the pro-rata IN-KIND slice then
    ///      self-swaps the unwanted leg into `tokenOut` bounded by the SAME on-chain TWAP slippage
    ///      bound; output ≤ pro-rata NAV by construction. Reverts SingleOutTooLow if `minOut` unmet.
    function _settleSingle(
        TrancheState storage tr,
        PoolInfo storage p,
        VaultOps.Ctx memory c,
        WithdrawRequest storage r,
        address owner,
        uint256 shares,
        uint256 totalShares
    ) internal returns (uint256 amountOut) {
        bool wantToken0 = r.tokenOut == Currency.unwrap(p.key.currency0);

        // Pro-rata slice of held (non-banded) balances — floor, reserve-first debit.
        uint256 held0 = FullMath.mulDiv(shares, tr.pending0 + tr.reserve0, totalShares);
        uint256 held1 = FullMath.mulDiv(shares, tr.pending1 + tr.reserve1, totalShares);
        _debitHeldPreferReserve(tr, held0, held1);

        IFeraShare(tr.share).burn(address(this), shares);
        amountOut = abi.decode(
            c.pm.unlock(abi.encode(CB_WITHDRAW_SINGLE, c.id, c.t, abi.encode(shares, totalShares, wantToken0, held0, held1))),
            (uint256)
        );
        if (amountOut < r.minOut) revert IFeraVault.SingleOutTooLow();
        IERC20(r.tokenOut).safeTransfer(owner, amountOut);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // FLAG / RESOLVE / CANCEL — the incident-freeze + owner-resolution + anti-trap-cancel surface.
    // Access control (onlyGuardian / onlyOwner / owner==caller) stays on the vault wrappers; the
    // request-state guards + mutation + share-return live here (bytecode relief). Returning shares uses
    // a plain transfer from the vault (never transfer-locked — the vault is never a depositor), and
    // NEVER moves assets, so it is solvency-neutral and cannot bypass the delay.
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Guardian FREEZE: mark a still-pending request flagged (freeze-only — no seize/burn).
    function flag(mapping(uint256 => WithdrawRequest) storage requests, uint256 reqId, address guardian) public {
        WithdrawRequest storage r = requests[reqId];
        if (r.owner == address(0)) revert IFeraVault.UnknownRequest();
        if (r.settled) revert IFeraVault.RequestSettled();
        r.flagged = true;
        emit IFeraVault.WithdrawFlagged(reqId, guardian);
    }

    /// @notice Owner resolution of a FLAGGED request. `release=true` clears the flag; `release=false`
    ///         RETURNS the escrowed shares to the owner and voids it. The owner can ALWAYS resolve, so
    ///         a frozen request is never trapped.
    function resolve(
        mapping(uint256 => WithdrawRequest) storage requests,
        mapping(PoolId => mapping(uint256 => TrancheState)) storage tranches,
        uint256 reqId,
        bool release
    ) public {
        WithdrawRequest storage r = requests[reqId];
        if (r.owner == address(0)) revert IFeraVault.UnknownRequest();
        if (r.settled) revert IFeraVault.RequestSettled();
        if (!r.flagged) revert IFeraVault.RequestNotFlagged();
        if (release) {
            r.flagged = false;
            emit IFeraVault.WithdrawFlagResolved(reqId);
        } else {
            r.settled = true; // void (terminal) — before the external share transfer (CEI)
            IFeraShare(tranches[r.id][r.t].share).transfer(r.owner, r.shares);
            emit IFeraVault.WithdrawReturned(reqId, r.owner, r.shares);
        }
    }

    /// @notice Anti-trap self-CANCEL: the request owner reclaims their own escrowed shares from a
    ///         still-pending, un-flagged request, voiding it. Returns SHARES only (no assets).
    function cancel(
        mapping(uint256 => WithdrawRequest) storage requests,
        mapping(PoolId => mapping(uint256 => TrancheState)) storage tranches,
        uint256 reqId,
        address caller
    ) public {
        WithdrawRequest storage r = requests[reqId];
        if (caller != r.owner) revert IFeraVault.NotRequestOwner(); // implies owner != address(0)
        if (r.settled) revert IFeraVault.RequestSettled();
        if (r.flagged) revert IFeraVault.RequestFlagged(); // frozen: only the owner-resolve can move it
        r.settled = true; // void (terminal) — before the external share transfer (CEI)
        IFeraShare(tranches[r.id][r.t].share).transfer(r.owner, r.shares);
        emit IFeraVault.WithdrawCanceled(reqId, r.owner, r.shares);
    }

    // ── local port of the held-balance debit helper ────────────────────────────────────────────
    function _debitHeldPreferReserve(TrancheState storage tr, uint256 amt0, uint256 amt1) internal {
        uint256 r0 = amt0 < tr.reserve0 ? amt0 : tr.reserve0;
        tr.reserve0 -= r0;
        if (amt0 - r0 != 0) tr.pending0 -= (amt0 - r0);
        uint256 r1 = amt1 < tr.reserve1 ? amt1 : tr.reserve1;
        tr.reserve1 -= r1;
        if (amt1 - r1 != 0) tr.pending1 -= (amt1 - r1);
    }
}
