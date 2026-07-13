// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EsFera} from "../../src/EsFera.sol";
import {FeraToken} from "../../src/FeraToken.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {AnchorStaking} from "../../src/AnchorStaking.sol";
import {IFeraToken} from "../../src/interfaces/IFeraToken.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IEsFera} from "../../src/interfaces/IEsFera.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice R-20 (skill-audit CRITICAL) regression — EsFera `instantExit` re-vesting drain.
///
///   ROOT CAUSE (pre-fix): `_consumeLocked` shrank a vest's `amount` without touching `claimed`, and
///   `_vestedOf = amount·elapsed/dur` recomputed on the shrunk amount, so `locked = amount − vested`
///   REGENERATED. Repeated instantExit extracted a geometric series ≈ the full original amount ON TOP
///   of any claimVested already paid → a 100-FERA vest paid out **190** (attacker +40%), draining 90
///   of other vesters' shared FERA backing (their later claims revert = insolvency).
///
///   FIX: `amount` is immutable; a separate `exited` accumulator records early-exited principal.
///        locked = amount − vestedByTime − exited (floored);  claimable ceiling = min(vestedByTime,
///        amount − exited) − claimed. Conservation: claimed + exited ≤ amount, ALWAYS.
///
///   These tests would have FAILED before the fix and PASS after it.
contract EsFeraExitPoCTest is Test {
    FeraToken internal fera;
    EsFera internal es;
    RevenueDistributor internal rev;
    // REC-8: staking is the REAL AnchorStaking so `_routeForfeit` can BOOK the stakers-third (not an
    // EOA). These PoCs never stake, so the third is held as pendingForfeitFera — still physically at
    // staking, so `_totalReleased` (which counts staking's FERA balance) is unaffected.
    AnchorStaking internal staking;

    address internal treasury = makeAddr("treasury");
    address internal ops = makeAddr("ops");
    address internal attacker = makeAddr("attacker");
    address internal honest = makeAddr("honest");

    uint256 internal constant DUR = FeraConstants.ES_VEST_DURATION;

    function setUp() public {
        fera = new FeraToken(address(this)); // genesis 10% (1e26) mints to this test contract
        // Break the AnchorStaking↔RevenueDistributor ctor cycle by predicting staking's address.
        address predictedStaking = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rev = new RevenueDistributor(predictedStaking, treasury, ops);
        staking = new AnchorStaking(IERC20(address(fera)), IRevenueDistributor(address(rev)), address(this));
        require(address(staking) == predictedStaking, "staking addr mismatch");
        // minter = this test contract, so we can open vests directly.
        es = new EsFera(IFeraToken(address(fera)), IAnchorStaking(address(staking)), IRevenueDistributor(address(rev)), address(this));
        // REC-8 deploy dependency: allowlist FERA + wire EsFera as the forfeit notifier.
        staking.addRewardToken(address(fera));
        staking.setForfeitNotifier(address(es));
        vm.warp(1_000_000); // sane epoch so vest windows are well-defined
    }

    function _fund(uint256 amt) internal {
        IERC20(address(fera)).transfer(address(es), amt);
    }

    /// @dev Total FERA that has irreversibly LEFT the escrow across ALL paths for the grants under
    ///      test: what the attacker kept + the routed forfeit thirds (stakers + revenue) + burned.
    function _totalReleased(uint256 supplyBefore) internal view returns (uint256) {
        uint256 burned = supplyBefore - fera.totalSupply();
        return fera.balanceOf(attacker) + fera.balanceOf(address(staking)) + fera.balanceOf(address(rev)) + burned;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 1. The documented drain is now UNPROFITABLE — a 100-vest can never pay out > 100.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_R20_repeatedInstantExit_100vestPaysAtMost100() public {
        uint256 amount = 100e18;
        _fund(amount); // EXACT backing — a single grant, nothing else to steal from
        es.mintAndVest(attacker, amount);
        uint256 supplyBefore = fera.totalSupply();

        // Attacker vests to 90%, claims the vested 90, then hammers instantExit trying to regenerate
        // "locked" principal (the pre-fix drain). Loop far more than any legitimate exit could need.
        vm.warp(block.timestamp + (DUR * 9) / 10);
        vm.startPrank(attacker);
        es.claimVested();
        for (uint256 i; i < 64; ++i) {
            uint256 locked = es.lockedOf(attacker);
            if (locked == 0) break;
            es.instantExit(locked);
        }
        // Locked principal must NOT regenerate: further exits revert.
        vm.expectRevert(IEsFera.NothingVesting.selector);
        es.instantExit(1);
        vm.stopPrank();

        // Even letting the whole schedule finish yields nothing extra (exited principal can't re-vest).
        vm.warp(block.timestamp + DUR);
        vm.prank(attacker);
        vm.expectRevert(IEsFera.NothingVesting.selector);
        es.claimVested();

        uint256 released = _totalReleased(supplyBefore);
        // CORE ASSERTION: total FERA out for the 100-grant ≤ 100 (pre-fix this was 190).
        assertLe(released, amount, "grant released more FERA than it was minted for (R-20 drain)");
        // Attacker personally can never net a profit above the principal (pre-fix: netted 140).
        assertLe(fera.balanceOf(attacker), amount, "attacker net exceeds principal");
        // Sanity: with a 90% claim + exit of the remaining 10% locked, attacker keeps ~95 (90 + 5).
        assertApproxEqAbs(fera.balanceOf(attacker), 95e18, 1e15, "unexpected attacker payout profile");
        // Escrow accounting stays solvent: outstanding never over-decrements below real backing.
        assertGe(fera.balanceOf(address(es)), es.outstandingEsFera(), "outstanding > backing (insolvent)");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 2. The drain can no longer starve OTHER vesters (the insolvency the CRITICAL caused).
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_R20_drainDoesNotStarveOtherVesters() public {
        uint256 amount = 100e18;
        _fund(2 * amount); // EXACT backing for two grants — pre-fix the attacker drained the honest one
        es.mintAndVest(attacker, amount);
        es.mintAndVest(honest, amount);

        // Attacker maximally exploits: claim at 90% then hammer instantExit.
        vm.warp(block.timestamp + (DUR * 9) / 10);
        vm.startPrank(attacker);
        es.claimVested();
        for (uint256 i; i < 64; ++i) {
            uint256 locked = es.lockedOf(attacker);
            if (locked == 0) break;
            es.instantExit(locked);
        }
        vm.stopPrank();

        // Honest vester rides to full maturity and claims — this MUST NOT revert for insolvency.
        vm.warp(block.timestamp + DUR);
        vm.prank(honest);
        uint256 honestOut = es.claimVested();
        assertEq(honestOut, amount, "honest vester could not claim their full backing (insolvency)");
        assertEq(fera.balanceOf(honest), amount, "honest payout short");
        assertGe(fera.balanceOf(address(es)), es.outstandingEsFera(), "escrow insolvent");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 3. Conservation invariant (fuzz): claim + exit interleavings never release > amount.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function testFuzz_R20_grantConservation(uint256 amount, uint256 exitBps, uint256 warpBps) public {
        amount = bound(amount, 1e6, 1e24);
        exitBps = bound(exitBps, 0, 10_000);
        warpBps = bound(warpBps, 0, 12_000); // allow past-end warps too

        _fund(amount); // single grant, exact backing
        es.mintAndVest(attacker, amount);
        uint256 supplyBefore = fera.totalSupply();

        // Partial early exit of currently-locked principal.
        vm.startPrank(attacker);
        uint256 locked0 = es.lockedOf(attacker);
        uint256 exitAmt = (locked0 * exitBps) / 10_000;
        if (exitAmt != 0) es.instantExit(exitAmt);

        // Advance time, claim what vested.
        vm.warp(block.timestamp + (DUR * warpBps) / 10_000);
        if (es.claimable(attacker) != 0) es.claimVested();

        // Try to drain any regenerated locked (must be bounded to real remaining locked).
        for (uint256 i; i < 32; ++i) {
            uint256 locked = es.lockedOf(attacker);
            if (locked == 0) break;
            es.instantExit(locked);
        }
        // Final claim after full maturity.
        vm.warp(block.timestamp + DUR);
        if (es.claimable(attacker) != 0) es.claimVested();
        vm.stopPrank();

        uint256 released = _totalReleased(supplyBefore);
        assertLe(released, amount, "conservation broken: grant released more than minted");
        assertGe(fera.balanceOf(address(es)), es.outstandingEsFera(), "outstanding exceeds backing");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // 4. Secondary self-DoS is gone: claim → exit → claim never underflow-reverts.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_R20_claimThenExitThenClaim_noUnderflowDoS() public {
        uint256 amount = 100e18;
        _fund(amount);
        es.mintAndVest(attacker, amount);

        vm.warp(block.timestamp + DUR / 2); // 50% vested
        vm.startPrank(attacker);
        es.claimVested(); // claimed ≈ 50
        uint256 locked = es.lockedOf(attacker); // ≈ 50 still locked
        assertGt(locked, 0, "expected locked principal at midpoint");
        es.instantExit(locked / 2); // exit part of the locked half

        // Pre-fix this poisoned the vest so claimable underflow-reverted; now it must succeed cleanly.
        vm.warp(block.timestamp + DUR); // fully mature
        es.claimVested(); // must NOT revert (pre-fix: underflow revert)
        vm.stopPrank();

        // Total for the grant still conserves.
        assertLe(fera.balanceOf(attacker), amount, "grant over-released");
        assertGe(fera.balanceOf(address(es)), es.outstandingEsFera(), "escrow insolvent");
    }
}
