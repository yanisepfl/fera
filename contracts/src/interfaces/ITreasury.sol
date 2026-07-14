// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title ITreasury
/// @notice Timelocked (48h) treasury sink. Receives genesis 10% FERA (vested), the emission
///         treasury share, and the revenue treasury 25%. All outflows pass a 48h delay (INV-12).
///         MASTER_SPEC §3, §7.
/// @dev    STATUS (stage-3): kept unused in the live deploy, which wires a plain treasury EOA
///         instead — see `Treasury.sol`'s NatSpec / `contracts/OPEN_DECISIONS.md`#OD-9.
interface ITreasury {
    event Queued(bytes32 indexed id, address indexed target, uint256 value, bytes data, uint256 eta);
    event Executed(bytes32 indexed id, address indexed target, uint256 value, bytes data);
    event Cancelled(bytes32 indexed id);

    error NotReady();
    error AlreadyQueued();
    error Unauthorized();
    error CallReverted();

    /// @notice The immutable 48h delay applied to every queued action.
    function DELAY() external view returns (uint256);

    /// @notice Queue an arbitrary treasury action; executable after now + DELAY.
    function queue(address target, uint256 value, bytes calldata data) external returns (bytes32 id);

    /// @notice Execute a previously-queued action once its ETA has passed.
    function execute(address target, uint256 value, bytes calldata data, uint256 eta) external returns (bytes memory);

    /// @notice Cancel a queued action before execution (governor-only).
    function cancel(bytes32 id) external;
}
