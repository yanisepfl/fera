// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeraVault} from "../../src/FeraVault.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice INV-3 — performance fee is EXACTLY 10% of collected LP fees and 0% of principal.
/// @dev    `previewPerfFee` is a pure function: principal never enters it, so it is structurally
///         impossible for the perf fee to touch principal. This proves the fee-math arm of INV-3.
///         The full collect-path skim (fee routing to RevenueDistributor) is exercised in the v4
///         integration test (test/integration/VaultLifecycle.t.sol).
contract PerfFeeTest is Test {
    FeraVault internal vault;

    function setUp() public {
        // previewPerfFee is pure; the vault is deployed only to call it (dummy immutables are fine).
        vault = new FeraVault(
            IPoolManager(address(0xA11)),
            IFeraHook(address(0xB22)),
            IRevenueDistributor(address(0xC33)),
            address(0xD44), // share impl
            address(0xE55), // keeper
            address(this) // timelock owner
        );
    }

    /// Perf fee is floor(10%) of fee; LP keeps the remainder; the two always reconstruct the fee.
    function testFuzz_perfFee_isExactly10Percent(uint256 fee0, uint256 fee1) public view {
        fee0 = bound(fee0, 0, 1e40);
        fee1 = bound(fee1, 0, 1e40);

        (uint256 perf0, uint256 perf1, uint256 lp0, uint256 lp1) = vault.previewPerfFee(fee0, fee1);

        assertEq(perf0, (fee0 * FeraConstants.PERF_FEE_BPS) / FeraConstants.BPS, "perf0 != 10%");
        assertEq(perf1, (fee1 * FeraConstants.PERF_FEE_BPS) / FeraConstants.BPS, "perf1 != 10%");

        // Conservation: nothing created or destroyed between perf + lp.
        assertEq(perf0 + lp0, fee0, "fee0 not conserved");
        assertEq(perf1 + lp1, fee1, "fee1 not conserved");

        // Perf fee never EXCEEDS 10% (floor rounding always favors LPs).
        assertLe(perf0 * 10, fee0 + 9, "perf0 > 10% band");
        assertLe(perf1 * 10, fee1 + 9, "perf1 > 10% band");

        // And is never more than 1 wei below the nominal 10% (tight floor).
        if (fee0 >= 10) assertGe(perf0, fee0 / 10 - 1, "perf0 loose floor");
    }

    /// Exact-value spot checks: 10% of a round number is exact; small values floor to 0.
    function test_perfFee_spotValues() public view {
        (uint256 perf0,,,) = vault.previewPerfFee(1_000, 0);
        assertEq(perf0, 100, "10% of 1000 != 100");

        (uint256 perfSmall,,,) = vault.previewPerfFee(9, 0);
        assertEq(perfSmall, 0, "sub-10 fee should floor to 0 perf");

        (, uint256 perf1, uint256 lp0,) = vault.previewPerfFee(0, 1e18);
        assertEq(perf1, 1e17, "10% of 1e18 != 1e17");
        assertEq(lp0, 0, "lp0 should be 0 when fee0 is 0");
    }

    /// PERF_FEE_BPS is the immutable 10% mandated by MASTER_SPEC §7 / PARAMS.md#PERF_FEE_BPS.
    function test_perfFeeConstant_is1000bps() public pure {
        assertEq(FeraConstants.PERF_FEE_BPS, 1_000);
    }
}
