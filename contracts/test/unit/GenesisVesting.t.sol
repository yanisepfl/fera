// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenesisVesting} from "../../src/GenesisVesting.sol";
import {IGenesisVesting} from "../../src/interfaces/IGenesisVesting.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {MintableERC20} from "../utils/Mocks.sol";

/// @notice Stage-3 (contracts/VAULT_STRATEGY_V3.md §10): the 10% FERA genesis allocation
///         (100,000,000 FERA) is locked in `GenesisVesting` with a single beneficiary (the
///         treasury EOA) under a 1-YEAR CLIFF then LINEAR VESTING over the following 3 YEARS
///         (4-year total horizon). Covers exactly the TESTS matrix from the decided spec:
///          - nothing claimable before the cliff (fuzzed timestamps, always 0);
///          - exact proportional linear release after the cliff (fuzzed timestamps), monotonic;
///          - fully claimable at/after the 4-year mark, never more than the total;
///          - permissionless-pull claim() always pays the fixed beneficiary, never the caller.
contract GenesisVestingTest is Test {
    GenesisVesting internal vesting;
    MintableERC20 internal token;

    address internal beneficiary = makeAddr("treasuryEoa");

    // The exact genesis allocation size (100,000,000 FERA), computed the same way FeraToken does.
    uint256 internal constant TOTAL_ALLOCATION =
        (FeraConstants.FERA_MAX_SUPPLY * FeraConstants.GENESIS_TREASURY_BPS) / FeraConstants.BPS;

    uint256 internal start;
    uint256 internal cliffEnd;
    uint256 internal vestEnd;

    function setUp() public {
        vm.warp(1_800_000_000); // fixed, realistic epoch so cliff/end math is easy to reason about
        token = new MintableERC20("FERA", "FERA");

        vesting = new GenesisVesting(token, beneficiary);
        // Simulate FeraToken's constructor: genesis mint lands here directly, post-construction.
        token.mint(address(vesting), TOTAL_ALLOCATION);

        start = vesting.start();
        cliffEnd = start + FeraConstants.GENESIS_VESTING_CLIFF_DURATION;
        vestEnd = start + FeraConstants.GENESIS_VESTING_TOTAL_DURATION;
    }

    // ── constructor ──────────────────────────────────────────────────────────────────────────

    function test_constructor_wiresImmutables() public view {
        assertEq(address(vesting.token()), address(token));
        assertEq(vesting.beneficiary(), beneficiary);
        assertEq(vesting.start(), block.timestamp);
        assertEq(vesting.released(), 0);
    }

    function test_constructor_rejectsZeroToken() public {
        vm.expectRevert(IGenesisVesting.ZeroAddress.selector);
        new GenesisVesting(MintableERC20(address(0)), beneficiary);
    }

    function test_constructor_rejectsZeroBeneficiary() public {
        vm.expectRevert(IGenesisVesting.ZeroAddress.selector);
        new GenesisVesting(token, address(0));
    }

    function test_scheduleConstants_matchDecidedSpec() public view {
        // 1yr cliff, 4yr total horizon (⇒ 3yr linear release after the cliff).
        assertEq(FeraConstants.GENESIS_VESTING_CLIFF_DURATION, 365 days);
        assertEq(FeraConstants.GENESIS_VESTING_TOTAL_DURATION, 4 * 365 days);
        assertEq(cliffEnd - start, 365 days);
        assertEq(vestEnd - start, 4 * 365 days);
    }

    // ── nothing claimable before the cliff ──────────────────────────────────────────────────

    /// Any timestamp strictly before the cliff ⇒ vestedAmount == 0 == releasable, ALWAYS.
    function testFuzz_nothingClaimableBeforeCliff(uint256 t) public {
        t = bound(t, 0, cliffEnd - 1);
        assertEq(vesting.vestedAmount(t), 0, "vestedAmount must be 0 strictly before the cliff");
        if (t == block.timestamp) {
            assertEq(vesting.releasable(), 0, "releasable must be 0 strictly before the cliff");
        }
    }

    function test_claim_beforeCliff_reverts() public {
        vm.warp(cliffEnd - 1);
        vm.expectRevert(IGenesisVesting.NothingToClaim.selector);
        vesting.claim();
    }

    function test_atExactCliff_stillZero() public view {
        // The formula is a strict `<` on the cliff boundary itself — claimable turns on the
        // instant AFTER the cliff elapses, not exactly at it (elapsed - cliff == 0 there anyway).
        assertEq(vesting.vestedAmount(cliffEnd), 0, "at the exact cliff instant, elapsed-since-cliff is 0");
    }

    // ── linear release after the cliff ──────────────────────────────────────────────────────

    /// For any timestamp within (cliffEnd, vestEnd), vestedAmount must equal the EXACT proportional
    /// linear formula: total * (t - cliffEnd) / (vestEnd - cliffEnd).
    function testFuzz_linearReleaseAfterCliff_exactProportional(uint256 t) public view {
        t = bound(t, cliffEnd, vestEnd - 1);
        uint256 expected = (TOTAL_ALLOCATION * (t - cliffEnd)) / (vestEnd - cliffEnd);
        assertEq(vesting.vestedAmount(t), expected, "vestedAmount must match the exact linear formula");
        assertLe(vesting.vestedAmount(t), TOTAL_ALLOCATION, "vestedAmount must never exceed the total");
    }

    /// Monotonic non-decreasing: for any t1 <= t2 (spanning before/within/after the schedule),
    /// vestedAmount(t1) <= vestedAmount(t2). This is the core "can never go backwards" property.
    function testFuzz_vestedAmount_monotonicNonDecreasing(uint256 t1, uint256 t2) public view {
        t1 = bound(t1, 0, vestEnd + 400 days);
        t2 = bound(t2, t1, vestEnd + 400 days);
        assertLe(vesting.vestedAmount(t1), vesting.vestedAmount(t2), "vestedAmount must be monotonic non-decreasing");
    }

    /// vestedAmount must never exceed the total allocation, for ANY timestamp (including far past
    /// the horizon, and including timestamp 0).
    function testFuzz_vestedAmount_neverExceedsTotal(uint256 t) public view {
        t = bound(t, 0, type(uint256).max / 2); // avoid the (start + duration) additions overflowing
        assertLe(vesting.vestedAmount(t), TOTAL_ALLOCATION, "vestedAmount must never exceed the total");
    }

    /// Claiming at increasing timestamps only ever increases cumulative released FERA, and the
    /// cumulative amount matches the schedule at each step (checks real state mutation, not just
    /// the pure view function).
    function testFuzz_incrementalClaims_conserveAndNeverExceed(uint256 tMid, uint256 tLate) public {
        // FIX (memo 08 F-1, test-only harness bug): the previous bounds were INCLUSIVE at the cliff
        // (`cliffEnd`) and at `tMid`, which admit `tMid == cliffEnd` (releasable == 0) and
        // `tLate == tMid` (nothing new vested). At those boundaries `claim()` CORRECTLY reverts
        // `NothingToClaim` (intended, safe behavior — see test_atExactCliff_stillZero), so the
        // unconditional `claim()` calls below flake red on those reachable inputs. The contract is
        // correct; the bounds must exclude the zero-releasable boundaries. `cliffEnd + 1` yields
        // expectedMid ≈ 1.05e18 > 0; `tMid + 1` guarantees a strictly-positive second claim, and
        // `tMid + 1 <= vestEnd <= vestEnd + 365d` keeps the bound valid.
        tMid = bound(tMid, cliffEnd + 1, vestEnd - 1);
        tLate = bound(tLate, tMid + 1, vestEnd + 365 days);

        vm.warp(tMid);
        uint256 expectedMid = (TOTAL_ALLOCATION * (tMid - cliffEnd)) / (vestEnd - cliffEnd);
        uint256 firstClaim = vesting.claim();
        assertEq(firstClaim, expectedMid, "first claim must equal the schedule at tMid");
        assertEq(vesting.released(), firstClaim);
        assertEq(token.balanceOf(beneficiary), firstClaim);

        vm.warp(tLate);
        uint256 expectedLateTotal = vesting.vestedAmount(tLate);
        uint256 secondClaim = vesting.releasable();
        vesting.claim();
        assertEq(vesting.released(), expectedLateTotal, "cumulative released must match the schedule at tLate");
        assertEq(token.balanceOf(beneficiary), firstClaim + secondClaim, "beneficiary balance must equal cumulative claims");
        assertLe(vesting.released(), TOTAL_ALLOCATION, "cumulative released must never exceed the total");
    }

    // ── fully claimable at/after the 4-year mark ────────────────────────────────────────────

    function test_fullyClaimableAtFourYearMark() public {
        vm.warp(vestEnd);
        assertEq(vesting.vestedAmount(vestEnd), TOTAL_ALLOCATION, "must be fully vested at exactly the 4yr mark");
        uint256 claimed = vesting.claim();
        assertEq(claimed, TOTAL_ALLOCATION, "claim must release the FULL allocation at the 4yr mark");
        assertEq(token.balanceOf(beneficiary), TOTAL_ALLOCATION);
        assertEq(vesting.releasable(), 0, "nothing left to claim after claiming everything");
    }

    function testFuzz_fullyClaimableAnyTimeAfterFourYears(uint256 t) public view {
        t = bound(t, vestEnd, vestEnd + 100 * 365 days);
        assertEq(vesting.vestedAmount(t), TOTAL_ALLOCATION, "must stay capped at the total forever after the horizon");
    }

    function test_claim_neverExceedsTotal_evenClaimedInPieces() public {
        // Claim repeatedly across the schedule; the SUM must never exceed TOTAL_ALLOCATION, and the
        // final claim (long after the horizon) must bring cumulative released to exactly the total.
        uint256[4] memory checkpoints =
            [cliffEnd + 100 days, cliffEnd + 500 days, vestEnd - 1, vestEnd + 10 days];
        uint256 cumulative;
        for (uint256 i; i < checkpoints.length; ++i) {
            vm.warp(checkpoints[i]);
            uint256 releasableNow = vesting.releasable();
            if (releasableNow == 0) continue;
            uint256 got = vesting.claim();
            assertEq(got, releasableNow);
            cumulative += got;
            assertLe(cumulative, TOTAL_ALLOCATION, "cumulative claimed must never exceed the total");
        }
        assertEq(cumulative, TOTAL_ALLOCATION, "after the horizon, cumulative claims must equal the full total");
    }

    // ── permissionless-pull: claim() always pays the fixed beneficiary ─────────────────────

    function test_claim_isPermissionlessPull_anyCallerMayTrigger_onlyBeneficiaryIsPaid() public {
        vm.warp(cliffEnd + 200 days);
        address randomCaller = makeAddr("randomCaller");

        vm.prank(randomCaller);
        uint256 amount = vesting.claim();

        assertGt(amount, 0, "expected a nonzero claim after the cliff");
        assertEq(token.balanceOf(beneficiary), amount, "funds must land at the fixed beneficiary");
        assertEq(token.balanceOf(randomCaller), 0, "the triggering caller must receive NOTHING");
    }

    function test_claim_emitsReleased() public {
        vm.warp(cliffEnd + 50 days);
        uint256 expected = vesting.releasable();
        vm.expectEmit(false, false, false, true, address(vesting));
        emit IGenesisVesting.Released(expected);
        vesting.claim();
    }

    function test_claim_secondCallSameBlock_revertsNothingToClaim() public {
        vm.warp(cliffEnd + 50 days);
        vesting.claim();
        vm.expectRevert(IGenesisVesting.NothingToClaim.selector);
        vesting.claim(); // nothing new vested since the last claim, same timestamp
    }
}
