// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IFeraToken} from "./interfaces/IFeraToken.sol";
import {FeraConstants} from "./libraries/FeraConstants.sol";

/// @title FeraToken (FERA)
/// @notice Fixed 1,000,000,000 supply. Genesis mints 10% to the Treasury (vested/timelocked there);
///         the remaining 90% is mintable EXCLUSIVELY by the EmissionsController and can never push
///         totalSupply past MAX_SUPPLY. No upgradeability (INV-12). MASTER_SPEC §3, §7.
/// @dev    Burnable so the esFERA instant-exit forfeit-burn third (INV-9) removes real supply;
///         burning only ever DECREASES supply, so the fixed-cap invariant is never threatened.
contract FeraToken is ERC20, ERC20Permit, ERC20Burnable, IFeraToken {
    /// @inheritdoc IFeraToken
    uint256 public constant MAX_SUPPLY = FeraConstants.FERA_MAX_SUPPLY;

    /// @inheritdoc IFeraToken
    address public emissionsController;

    /// @dev Deployer that wires the EmissionsController exactly once (breaks the FERA↔EC cycle).
    address private immutable _deployer;

    constructor(address treasury) ERC20("FERA", "FERA") ERC20Permit("FERA") {
        if (treasury == address(0)) revert ZeroAddress();
        _deployer = msg.sender;
        // Genesis: 10% to Treasury. The other 90% is minted over time by the EmissionsController.
        _mint(treasury, (MAX_SUPPLY * FeraConstants.GENESIS_TREASURY_BPS) / FeraConstants.BPS);
    }

    /// @notice One-shot wiring of the EmissionsController (the only future minter). Deployer-only.
    /// @dev    Immutable-after-set: cannot be repointed, so the 90% mint authority is locked.
    function setEmissionsController(address controller) external {
        if (msg.sender != _deployer) revert OnlyEmissionsController();
        if (controller == address(0)) revert ZeroAddress();
        if (emissionsController != address(0)) revert OnlyEmissionsController();
        emissionsController = controller;
    }

    /// @inheritdoc IFeraToken
    function mint(address to, uint256 amount) external {
        if (msg.sender != emissionsController) revert OnlyEmissionsController();
        if (totalSupply() + amount > MAX_SUPPLY) revert MintCapExceeded();
        _mint(to, amount);
    }
}
