// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeraToken} from "../../src/FeraToken.sol";
import {IFeraToken} from "../../src/interfaces/IFeraToken.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

/// @notice FERA is a fixed 1B supply token: 10% genesis to Treasury, 90% mintable ONLY by the
///         EmissionsController, never exceeding MAX_SUPPLY (MASTER_SPEC §3/§7, INV-12 fixed supply).
contract FeraTokenTest is Test {
    FeraToken internal fera;
    address internal treasury = makeAddr("treasury");
    address internal controller = makeAddr("controller");

    function setUp() public {
        fera = new FeraToken(treasury);
    }

    function test_genesis_mints10PercentToTreasury() public view {
        uint256 expected = (FeraConstants.FERA_MAX_SUPPLY * FeraConstants.GENESIS_TREASURY_BPS) / FeraConstants.BPS;
        assertEq(fera.balanceOf(treasury), expected, "genesis != 10%");
        assertEq(fera.totalSupply(), expected, "total supply != genesis at t0");
        assertEq(fera.MAX_SUPPLY(), 1_000_000_000e18);
    }

    function test_constructor_rejectsZeroTreasury() public {
        vm.expectRevert(IFeraToken.ZeroAddress.selector);
        new FeraToken(address(0));
    }

    function test_setEmissionsController_onceAndDeployerOnly() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IFeraToken.OnlyEmissionsController.selector);
        fera.setEmissionsController(controller);

        fera.setEmissionsController(controller);
        assertEq(fera.emissionsController(), controller);

        // Immutable-after-set: cannot repoint.
        vm.expectRevert(IFeraToken.OnlyEmissionsController.selector);
        fera.setEmissionsController(makeAddr("other"));
    }

    function test_mint_onlyController() public {
        fera.setEmissionsController(controller);
        vm.prank(makeAddr("notController"));
        vm.expectRevert(IFeraToken.OnlyEmissionsController.selector);
        fera.mint(address(this), 1e18);
    }

    function test_mint_respectsMaxSupply() public {
        fera.setEmissionsController(controller);
        uint256 genesis = fera.totalSupply();
        uint256 remaining = fera.MAX_SUPPLY() - genesis;

        vm.prank(controller);
        fera.mint(address(this), remaining); // exactly fills to cap
        assertEq(fera.totalSupply(), fera.MAX_SUPPLY());

        vm.prank(controller);
        vm.expectRevert(IFeraToken.MintCapExceeded.selector);
        fera.mint(address(this), 1); // one wei over cap
    }
}
