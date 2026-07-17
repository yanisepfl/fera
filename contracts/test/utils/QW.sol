// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FeraVault} from "../../src/FeraVault.sol";

/// @title QW — async-redemption test helper (universal 24h withdraw queue)
/// @notice The vault's instant `withdraw`/`withdrawSingle` were replaced by request → wait
///         WITHDRAW_DELAY_SEC → claim. These helpers reproduce the OLD synchronous return semantics
///         (so existing assertions stand) by driving the full flow: approve the vault to pull the
///         shares, `requestWithdraw*` as `who`, warp past the delay, then `claimWithdraw` (permission-
///         less; payout always to `who`).
/// @dev    Uses single-shot `vm.prank(who)` — do NOT call these while an outer `vm.startPrank` is
///         active (Foundry forbids overriding an active prank). Inside a startPrank block, expand the
///         flow inline instead. The share address is resolved BEFORE pranking so the view call does
///         not consume the prank.
library QW {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant DELAY = 24 hours; // FeraConstants.WITHDRAW_DELAY_SEC

    /// @notice Approve + `requestWithdraw` (in-kind) as `who`; returns the reqId.
    function request(FeraVault v, PoolId id, uint8 t, uint256 shares, uint256 min0, uint256 min1, address who)
        internal
        returns (uint256 reqId)
    {
        address share = v.shareToken(id, t);
        vm.prank(who);
        IERC20(share).approve(address(v), shares);
        vm.prank(who);
        reqId = v.requestWithdraw(id, t, shares, min0, min1);
    }

    /// @notice Approve + `requestWithdrawSingle` as `who`; returns the reqId.
    function requestSingle(FeraVault v, PoolId id, uint8 t, uint256 shares, address tokenOut, uint256 minOut, address who)
        internal
        returns (uint256 reqId)
    {
        address share = v.shareToken(id, t);
        vm.prank(who);
        IERC20(share).approve(address(v), shares);
        vm.prank(who);
        reqId = v.requestWithdrawSingle(id, t, shares, tokenOut, minOut);
    }

    /// @notice Full in-kind exit as `who`: request → warp past the delay → claim. Returns (amount0,
    ///         amount1) paid to `who`, matching the old `withdraw` return. In-kind claims never consult
    ///         the TWAP, so a long warp is always safe here.
    function drain(FeraVault v, PoolId id, uint8 t, uint256 shares, uint256 min0, uint256 min1, address who)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 reqId = request(v, id, t, shares, min0, min1, who);
        // Warp strictly past THIS request's STORED unlock. Do NOT recompute `block.timestamp + DELAY`
        // here: under via_ir the optimizer commons `block.timestamp` across the `vm.warp` cheatcode (it
        // cannot see the cheatcode mutate time), so a SECOND request→warp→claim in one test reuses a
        // stale pre-warp timestamp and undershoots the delay. The stored unlockTime is an external-call
        // return — the optimizer can't treat it as invariant, so this is cheatcode-proof.
        (,,,, uint64 unlockTime,,,,,,,) = v.withdrawRequests(reqId);
        vm.warp(uint256(unlockTime) + 1);
        (amount0, amount1) = v.claimWithdraw(reqId);
    }

    /// @notice Warp strictly past a request's STORED unlock, then let the test claim manually. Use this
    ///         (not an inline `vm.warp(block.timestamp + DELAY)`) whenever a test claims by hand —
    ///         ESPECIALLY for a SECOND request→warp→claim cycle in one test body: under via_ir the
    ///         optimizer commons `block.timestamp` across the `vm.warp` cheatcode, so an inline recompute
    ///         reuses a stale pre-warp timestamp and undershoots the delay. The stored unlockTime is an
    ///         external-call return, so it is cheatcode-proof.
    function warpPastUnlock(FeraVault v, uint256 reqId) internal {
        (,,,, uint64 unlockTime,,,,,,,) = v.withdrawRequests(reqId);
        vm.warp(uint256(unlockTime) + 1);
    }
}
