// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IRebalanceVenue
/// @notice Minimal adapter interface for a GOVERNANCE-WHITELISTED external venue (router / pool /
///         aggregator) the Vault MAY route a rebalancing token-ratio swap through when it quotes a
///         better price than the vault's own pool. The Vault enforces the SAME on-chain slippage
///         bound (`MAX_REBALANCE_SLIPPAGE_BPS` vs the pool TWAP) regardless of venue, and measures
///         the actual output by balance delta — it NEVER trusts the venue's return value for value
///         accounting, and the venue can never move value beyond the bound (bounded call).
/// @dev    The adapter is expected to pull `amountIn` of `tokenIn` from the caller (the Vault, which
///         approves it first) and deliver the swapped `tokenOut` to `recipient`. A concrete router
///         integration (Uniswap Universal Router / 1inch / etc.) is a thin implementation of this
///         interface; see VAULT_STRATEGY_V2.md — the production adapters are STUBBED in v2 (only the
///         interface + allowlist + bounded call + the test `MockRebalanceVenue` ship).
interface IRebalanceVenue {
    /// @notice Swap exactly `amountIn` of `tokenIn` into `tokenOut`, delivering the output to
    ///         `recipient`. MUST deliver at least `minOut` or revert. The Vault additionally
    ///         re-verifies the received amount against the pool TWAP after the call.
    /// @return amountOut the amount of `tokenOut` delivered to `recipient`.
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut);
}
