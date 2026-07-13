// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFeraToken
/// @notice Fixed 1,000,000,000 supply governance/emission token. 10% genesis to Treasury,
///         90% mintable exclusively by the EmissionsController (MASTER_SPEC §3, §7).
interface IFeraToken is IERC20 {
    error MintCapExceeded();
    error OnlyEmissionsController();
    error ZeroAddress();

    /// @notice The only address permitted to mint the remaining 90% (set once, immutable).
    function emissionsController() external view returns (address);

    /// @notice Fixed maximum supply (1e9 * 1e18). `totalSupply()` may never exceed this.
    function MAX_SUPPLY() external view returns (uint256);

    /// @notice Mint newly-emitted FERA. Reverts unless caller == emissionsController and the
    ///         mint keeps totalSupply ≤ MAX_SUPPLY.
    function mint(address to, uint256 amount) external;
}
