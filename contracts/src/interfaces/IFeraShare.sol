// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFeraShare
/// @notice Per-pool ERC-20 vault share token (D-1 / MASTER_SPEC §4). Deployed once as an
///         implementation and cloned (minimal proxy) per pool. Mint/burn gated to the Vault so
///         retail LPs hold a normal, composable wallet token representing their pool position.
interface IFeraShare is IERC20 {
    error OnlyVault();
    error AlreadyInitialized();
    /// @notice Reverts a transfer/transferFrom from an account whose deposit cooldown is still
    ///         active (V2-2 patch / SEC-3 #4). Closes the cooldown-evasion-by-transfer channel.
    error TransferLocked();

    /// @notice One-time initializer for a freshly-cloned share (sets Vault, poolId, name/symbol).
    function initialize(address vault_, bytes32 poolId_, string calldata name_, string calldata symbol_) external;

    /// @notice The Vault that exclusively controls mint/burn for this share.
    function vault() external view returns (address);

    /// @notice The v4 PoolId this share represents.
    function poolId() external view returns (bytes32);

    /// @notice Mint shares to `to`. Vault-only.
    function mint(address to, uint256 amount) external;

    /// @notice Burn shares from `from`. Vault-only.
    function burn(address from, uint256 amount) external;

    /// @notice Vault-only: lock `account`'s outgoing transfers until `until` (extends, never
    ///         shortens). Set by the Vault on every deposit so fresh shares cannot be moved to a
    ///         second wallet to dodge the withdraw cooldown (V2-2). Burn (redeem) is unaffected.
    function setTransferLock(address account, uint64 until) external;

    /// @notice Timestamp until which `account`'s outgoing share transfers are blocked (0 = none).
    function transferLockUntil(address account) external view returns (uint64);
}
