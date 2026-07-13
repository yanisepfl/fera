// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ITreasury} from "./interfaces/ITreasury.sol";
import {FeraConstants} from "./libraries/FeraConstants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Treasury
/// @notice Timelocked (48h, immutable) treasury sink. Holds genesis FERA, the emission treasury
///         share, and the revenue treasury 25%. Every outflow is queued and only executable after
///         48h, so there is no hot key over protocol funds (INV-12). No proxy (INV-12).
/// @dev    Minimal self-timelock: the governor (Ownable owner) queues → waits DELAY → executes.
///         Receiving funds is unrestricted; only spends are delayed.
contract Treasury is ITreasury, Ownable {
    /// @inheritdoc ITreasury
    uint256 public constant DELAY = FeraConstants.TIMELOCK_DELAY; // 48h, immutable

    /// @dev id ⇒ eta (0 = not queued). id = keccak256(abi.encode(target, value, data, eta)).
    mapping(bytes32 => bool) public queued;

    constructor(address governor) Ownable(governor) {}

    receive() external payable {}

    /// @inheritdoc ITreasury
    function queue(address target, uint256 value, bytes calldata data) external onlyOwner returns (bytes32 id) {
        uint256 eta = block.timestamp + DELAY;
        id = keccak256(abi.encode(target, value, data, eta));
        if (queued[id]) revert AlreadyQueued();
        queued[id] = true;
        emit Queued(id, target, value, data, eta);
    }

    /// @inheritdoc ITreasury
    function execute(address target, uint256 value, bytes calldata data, uint256 eta)
        external
        onlyOwner
        returns (bytes memory ret)
    {
        bytes32 id = keccak256(abi.encode(target, value, data, eta));
        if (!queued[id]) revert NotReady();
        if (block.timestamp < eta) revert NotReady();
        queued[id] = false; // effects before interaction

        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) revert CallReverted();
        emit Executed(id, target, value, data);
    }

    /// @inheritdoc ITreasury
    function cancel(bytes32 id) external onlyOwner {
        if (!queued[id]) revert NotReady();
        queued[id] = false;
        emit Cancelled(id);
    }
}
