// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IAggregatorV3
/// @notice Minimal Chainlink Data Feed interface (Robinhood Chain's official oracle infra,
///         SHARED_CONTEXT). Used by the Vault to re-verify RWA oracle price/staleness on-chain
///         (INV-6) and by the hook's RWA fee overlay. Full feed addresses come from docs/CHAIN.md.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
