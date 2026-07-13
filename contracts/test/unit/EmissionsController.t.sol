// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EmissionsController} from "../../src/EmissionsController.sol";
import {FeraToken} from "../../src/FeraToken.sol";
import {IFeraToken} from "../../src/interfaces/IFeraToken.sol";
import {IEmissionsController} from "../../src/interfaces/IEmissionsController.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

/// @notice INV-7 — epoch emission ≤ min( cap(t), β × epochRevenueValuedInFera ), enforced on-chain.
/// @dev    PT-5 / INV-13 note: the cap here is applied to the epoch TOTAL; the per-staker ≤2x boost
///         is applied off-chain (§9) INSIDE this total, so no boost can inflate the minted supply.
///         See EmissionsController.finalizeEpoch PT-5 hook + OPEN_DECISIONS.md#PT-5.
contract EmissionsControllerTest is Test {
    FeraToken internal fera;
    EmissionsController internal ec;
    address internal esFera = makeAddr("esFera");

    function setUp() public {
        fera = new FeraToken(makeAddr("treasury")); // genesis 10% to treasury
        ec = new EmissionsController(IFeraToken(address(fera)), esFera, address(this), address(this));
        fera.setEmissionsController(address(ec)); // this test is the deployer of FERA
    }

    function _warpPastEpoch(uint256 epochId) internal {
        vm.warp(ec.epochEnd(epochId) + 1);
    }

    /// Envelope = min(cap(t), β×revenue) for the current epoch-0 params (revenue small ⇒ β arm).
    function _envelope(uint256 revenue) internal view returns (uint256) {
        uint256 cap = ec.capAt(ec.epochEnd(0));
        uint256 revBound = (FeraConstants.BETA_DEFAULT_WAD * revenue) / 1e18;
        return cap < revBound ? cap : revBound;
    }

    /// Cannot finalize before the epoch is over.
    function test_finalize_beforeEpochOverReverts() public {
        vm.expectRevert(IEmissionsController.EpochNotOver.selector);
        ec.finalizeEpoch(0, 1e17, 1e18, 1e18);
    }

    /// D-BK-12: the controller funds EXACTLY the pipeline's committed total (ΣE_p), which may be
    /// strictly below the envelope — un-emittable remainders are never padded/redistributed.
    function test_finalize_fundsExactRequestedBelowEnvelope() public {
        _warpPastEpoch(0);
        uint256 revenue = 1e18; // β arm ⇒ envelope = 0.8e18
        uint256 envelope = _envelope(revenue);
        uint256 requested = envelope / 2; // pipeline ΣE_p strictly below the envelope

        uint256 emitted = ec.finalizeEpoch(0, requested, revenue, 1e18);

        assertEq(emitted, requested, "did not fund exactly the requested pipeline total");
        assertEq(ec.emittedOf(0), requested, "emittedOf not recorded (R-19 binding)");
        assertTrue(ec.finalized(0), "epoch not marked finalized");
        assertEq(fera.balanceOf(esFera), requested, "esFERA backing != funded amount");
        assertLe(emitted, envelope, "INV-7 envelope violated");
    }

    /// INV-7: requesting more than min(cap, β×revenue) reverts (the envelope is the hard ceiling).
    function test_finalize_requestAboveEnvelopeReverts() public {
        _warpPastEpoch(0);
        uint256 revenue = 1e18;
        uint256 envelope = _envelope(revenue);
        vm.expectRevert(IEmissionsController.EmissionBoundExceeded.selector);
        ec.finalizeEpoch(0, envelope + 1, revenue, 1e18);
    }

    /// Requesting EXACTLY the envelope is allowed (boundary), and funds the full envelope.
    function test_finalize_atEnvelopeAllowed() public {
        _warpPastEpoch(0);
        uint256 revenue = 1e18;
        uint256 envelope = _envelope(revenue);
        uint256 emitted = ec.finalizeEpoch(0, envelope, revenue, 1e18);
        assertEq(emitted, envelope, "emitted != envelope at the boundary");
    }

    /// INV-7 always: any accepted emission is ≤ BOTH bounds; any request above the envelope reverts.
    function testFuzz_finalize_neverExceedsEitherBound(uint256 revenue, uint256 requested) public {
        revenue = bound(revenue, 0, 1e30);
        _warpPastEpoch(0);
        uint256 cap = ec.capAt(ec.epochEnd(0));
        uint256 revenueBound = (FeraConstants.BETA_DEFAULT_WAD * revenue) / 1e18;
        uint256 envelope = cap < revenueBound ? cap : revenueBound;
        requested = bound(requested, 0, 2 * (envelope + 1));

        if (requested > envelope) {
            vm.expectRevert(IEmissionsController.EmissionBoundExceeded.selector);
            ec.finalizeEpoch(0, requested, revenue, 1e18);
        } else {
            uint256 emitted = ec.finalizeEpoch(0, requested, revenue, 1e18);
            assertEq(emitted, requested, "emitted != requested");
            assertLe(emitted, cap, "emitted > cap(t)");
            assertLe(emitted, revenueBound, "emitted > beta*revenue");
        }
    }

    /// An epoch can only be finalized once (double-emit protection).
    function test_finalize_onlyOnce() public {
        _warpPastEpoch(0);
        ec.finalizeEpoch(0, 1e17, 1e18, 1e18);
        vm.expectRevert(IEmissionsController.EpochAlreadyFinalized.selector);
        ec.finalizeEpoch(0, 1e17, 1e18, 1e18);
    }

    /// Only the keeper may finalize.
    function test_finalize_onlyKeeper() public {
        _warpPastEpoch(0);
        vm.prank(makeAddr("notKeeper"));
        vm.expectRevert(IEmissionsController.OnlyKeeper.selector);
        ec.finalizeEpoch(0, 1e17, 1e18, 1e18);
    }

    /// β setter is bounded (timelock owner only) — supports INV-12 timelocked-param class.
    function test_setBeta_bounds() public {
        vm.expectRevert(); // > 1e18 rejected
        ec.setBeta(2e18);
        ec.setBeta(0.9e18);
        assertEq(ec.beta(), 0.9e18);
    }

    /// β setter rejects zero (the lower bound of the (0, 0.9] legal window).
    function test_setBeta_zeroRejected() public {
        vm.expectRevert();
        ec.setBeta(0);
    }

    // ── capAt(t) placeholder S-curve — the two clamp legs the finalize tests don't reach ────
    /// Past the ~4-year horizon the cumulative cap saturates at the 900M asymptote (L).
    function test_capAt_horizonSaturatesAtL() public view {
        uint256 t = ec.genesisTs() + 4 * 365 days + 1;
        assertEq(ec.capAt(t), FeraConstants.CAP_LOGISTIC_L, "cap did not saturate at L past the horizon");
        // The exact horizon boundary also returns L (elapsed >= horizon).
        assertEq(ec.capAt(ec.genesisTs() + 4 * 365 days), FeraConstants.CAP_LOGISTIC_L, "cap at horizon boundary != L");
    }

    /// At or before genesis the cumulative cap is zero (nothing emittable yet).
    function test_capAt_atOrBeforeGenesisIsZero() public view {
        assertEq(ec.capAt(ec.genesisTs()), 0, "cap at genesis should be 0");
        assertEq(ec.capAt(ec.genesisTs() - 1), 0, "cap before genesis should be 0");
    }

    /// Funding a zero committed total finalizes the epoch WITHOUT minting any FERA backing
    /// (the `emitted != 0` mint is skipped) — a legal empty epoch.
    function test_finalize_zeroRequest_finalizesWithoutMint() public {
        _warpPastEpoch(0);
        uint256 emitted = ec.finalizeEpoch(0, 0, 1e18, 1e18);
        assertEq(emitted, 0, "zero request should emit nothing");
        assertTrue(ec.finalized(0), "epoch not finalized");
        assertEq(ec.emittedOf(0), 0, "emittedOf should be 0");
        assertEq(fera.balanceOf(esFera), 0, "no FERA backing should have been minted for an empty epoch");
        assertEq(ec.totalEmitted(), 0, "totalEmitted should stay 0");
    }

    /// When β×revenue dominates the cap, the envelope is the CAP arm (marginalCap < revenueBound).
    function test_finalize_capBoundArm_emitsExactlyCap() public {
        _warpPastEpoch(0);
        uint256 hugeRevenue = 1e30; // β×revenue ≫ the epoch-0 linear-ramp cap
        uint256 cap = ec.capAt(ec.epochEnd(0));
        uint256 revenueBound = (FeraConstants.BETA_DEFAULT_WAD * hugeRevenue) / 1e18;
        assertLt(cap, revenueBound, "test precondition: cap must be the binding arm");
        uint256 emitted = ec.finalizeEpoch(0, cap, hugeRevenue, 1e18);
        assertEq(emitted, cap, "cap-bound epoch did not emit exactly the cap");
        // One wei above the cap arm is rejected.
        _warpPastEpoch(1);
        uint256 cap1 = ec.capAt(ec.epochEnd(1));
        uint256 marginal1 = cap1 - ec.totalEmitted();
        vm.expectRevert(IEmissionsController.EmissionBoundExceeded.selector);
        ec.finalizeEpoch(1, marginal1 + 1, hugeRevenue, 1e18);
    }

    // ── keeper rotation (owner == timelock) ─────────────────────────────────────────────────
    function test_setKeeper_rotates_and_gates() public {
        address keeper2 = makeAddr("keeper2");
        ec.setKeeper(keeper2);
        assertEq(ec.keeper(), keeper2, "keeper not rotated");

        _warpPastEpoch(0);
        // The OLD keeper (this test) can no longer finalize.
        vm.expectRevert(IEmissionsController.OnlyKeeper.selector);
        ec.finalizeEpoch(0, 1e17, 1e18, 1e18);
        // The NEW keeper can.
        vm.prank(keeper2);
        uint256 emitted = ec.finalizeEpoch(0, 1e17, 1e18, 1e18);
        assertEq(emitted, 1e17, "rotated keeper could not finalize");
    }

    function test_setKeeper_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        ec.setKeeper(makeAddr("x"));
    }

    function test_setKeeper_zeroAddressRejected() public {
        vm.expectRevert(IEmissionsController.ZeroAddress.selector);
        ec.setKeeper(address(0));
    }

    /// Constructor rejects a zero esFera sink or zero keeper (both `||` legs).
    function test_constructor_zeroAddressRejected() public {
        vm.expectRevert(IEmissionsController.ZeroAddress.selector);
        new EmissionsController(IFeraToken(address(fera)), address(0), address(this), address(this));
        vm.expectRevert(IEmissionsController.ZeroAddress.selector);
        new EmissionsController(IFeraToken(address(fera)), esFera, address(0), address(this));
    }

    /// currentEpoch advances with the genesis-anchored weekly clock.
    function test_currentEpoch_advances() public {
        assertEq(ec.currentEpoch(), 0, "should start in epoch 0");
        vm.warp(ec.genesisTs() + 3 * FeraConstants.EPOCH_LENGTH + 1);
        assertEq(ec.currentEpoch(), 3, "epoch clock did not advance to 3");
    }
}
