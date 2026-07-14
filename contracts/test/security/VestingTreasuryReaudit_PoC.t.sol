// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenesisVesting} from "../../src/GenesisVesting.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {MintableERC20, CallbackERC20, IReentrancyVictim} from "../utils/Mocks.sol";

/// @notice STAGE-3 RE-AUDIT — lens: genesis vesting + treasury-EOA (contracts/VAULT_STRATEGY_V3.md §10).
///         ADD-ONLY companion to `test/unit/GenesisVesting.t.sol`; covers the properties that suite
///         does NOT: (a) re-entrancy via an ERC-777-style callback token cannot double-claim,
///         (b) the OZ self-computing `total = balanceOf + released` stays airtight under a mid-schedule
///         token DONATION (no `releasable()` underflow, monotonicity + conservation preserved),
///         (c) the treasury being a plain EOA is fully honored by every remaining consumer of the
///         treasury address — RevenueDistributor's pull leg (both `notifyRevenue` and the v3.1
///         no-staker fold) works for a code-less account, proving NO code path assumes the treasury
///         is a contract.
contract VestingTreasuryReauditPoC is Test {
    // ── genesis size, computed exactly the way FeraToken does ───────────────────────────────────
    uint256 internal constant GENESIS =
        (FeraConstants.FERA_MAX_SUPPLY * FeraConstants.GENESIS_TREASURY_BPS) / FeraConstants.BPS;

    address internal treasuryEoa = makeAddr("treasuryEoa");

    function setUp() public {
        vm.warp(1_800_000_000);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // (a) Re-entrancy: a callback (ERC-777-style) token whose beneficiary re-enters claim() during
    //     the payout transfer CANNOT extract a second release. CEI (`released += amount` BEFORE
    //     `safeTransfer`) makes the inner claim see `releasable() == 0` and revert NothingToClaim.
    //     The existing unit suite only uses a plain non-callback MintableERC20, so this path is new.
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function test_reentrancy_callbackBeneficiaryCannotDoubleClaim() public {
        CallbackERC20 token = new CallbackERC20();
        ClaimReenterer reenterer = new ClaimReenterer();

        // beneficiary IS the reentering contract
        GenesisVesting vesting = new GenesisVesting(token, address(reenterer));
        reenterer.set(vesting);
        token.setCallback(address(reenterer), true); // fire onTokenReceived on transfer to beneficiary
        token.mint(address(vesting), GENESIS);

        uint256 cliffEnd = uint256(vesting.start()) + FeraConstants.GENESIS_VESTING_CLIFF_DURATION;
        vm.warp(cliffEnd + 200 days);

        uint256 expected = vesting.releasable();
        assertGt(expected, 0, "precondition: something is releasable");

        reenterer.arm();
        uint256 paid = reenterer.trigger(); // calls vesting.claim(); callback re-enters mid-transfer

        assertTrue(reenterer.innerReverted(), "re-entrant claim MUST revert (CEI: releasable==0 on re-entry)");
        assertEq(paid, expected, "outer claim releases exactly the scheduled amount, once");
        assertEq(vesting.released(), expected, "released increments by exactly one payout, not two");
        assertEq(token.balanceOf(address(reenterer)), expected, "beneficiary received the payout exactly ONCE");
        assertEq(token.balanceOf(address(vesting)), GENESIS - expected, "vault balance dropped by exactly one payout");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // (b) Self-computing-total robustness under a mid-schedule DONATION. The OZ pattern reads
    //     `total = balanceOf(this) + released` live, so an extra transfer INTO the contract raises
    //     `total`. This must never (i) make `releasable()` underflow/revert, (ii) break monotonicity
    //     of cumulative `released`, or (iii) let cumulative released exceed genesis+donation. Also
    //     confirms the donated surplus is fully claimable by the horizon (nothing stranded).
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function testFuzz_donationKeepsMathAirtight(uint256 tClaim, uint256 donation, uint256 tLater) public {
        MintableERC20 token = new MintableERC20("FERA", "FERA");
        GenesisVesting vesting = new GenesisVesting(token, treasuryEoa);
        token.mint(address(vesting), GENESIS);

        uint256 start = vesting.start();
        uint256 cliffEnd = start + FeraConstants.GENESIS_VESTING_CLIFF_DURATION;
        uint256 vestEnd = start + FeraConstants.GENESIS_VESTING_TOTAL_DURATION;

        tClaim = bound(tClaim, cliffEnd + 1, vestEnd - 1);
        donation = bound(donation, 0, 500_000_000e18); // up to half the max supply, arbitrary surplus
        tLater = bound(tLater, tClaim, vestEnd + 400 days);

        // First claim partway through the linear region.
        vm.warp(tClaim);
        uint256 relBefore = vesting.releasable();
        assertLe(vesting.released(), GENESIS, "released bounded by genesis pre-donation");
        uint256 c1 = vesting.claim();
        assertEq(c1, relBefore, "claim pays exactly releasable()");
        uint256 releasedAfterFirst = vesting.released();

        // Now DONATE extra tokens straight into the vesting contract (raises the live `total`).
        token.mint(address(vesting), donation);

        // releasable() must NOT underflow/revert even though `released>0` and total just jumped.
        vesting.releasable(); // reverts on underflow — a plain call is the assertion
        uint256 vestedAtDonation = vesting.vestedAmount(block.timestamp);
        assertGe(
            vestedAtDonation, releasedAfterFirst, "vestedAmount(now) >= released: releasable() can never underflow"
        );

        // Warp later and drain.
        vm.warp(tLater);
        // monotonic in time: with total now fixed at genesis+donation, later vestedAmount can only grow
        assertGe(vesting.vestedAmount(block.timestamp), vestedAtDonation, "vestedAmount is monotonic across the warp");
        if (vesting.releasable() > 0) {
            vesting.claim();
        }

        uint256 totalPot = GENESIS + donation;
        assertLe(vesting.released(), totalPot, "cumulative released can never exceed genesis + donation");
        assertLe(token.balanceOf(treasuryEoa), totalPot, "beneficiary never receives more than the whole pot");

        // At/after the horizon, the ENTIRE pot (genesis + donation) is fully vested — nothing stranded.
        if (tLater >= vestEnd) {
            assertEq(vesting.vestedAmount(block.timestamp), totalPot, "whole pot vested at/after horizon");
            assertEq(vesting.released(), totalPot, "whole pot released once the horizon is reached");
            assertEq(vesting.releasable(), 0, "nothing left to claim");
        }
    }

    // A tighter deterministic monotonicity walk across the WHOLE domain (before/at/within/after),
    // claiming greedily at each step; cumulative released is non-decreasing and never exceeds genesis.
    function test_greedyWalk_monotonicAndConserved() public {
        MintableERC20 token = new MintableERC20("FERA", "FERA");
        GenesisVesting vesting = new GenesisVesting(token, treasuryEoa);
        token.mint(address(vesting), GENESIS);

        uint256 start = vesting.start();
        uint256 vestEnd = start + FeraConstants.GENESIS_VESTING_TOTAL_DURATION;

        uint256 prevReleased;
        // step in ~1-week increments from just before deploy to well past the horizon
        for (uint256 t = start; t <= vestEnd + 30 days; t += 7 days) {
            vm.warp(t);
            if (vesting.releasable() > 0) vesting.claim();
            assertGe(vesting.released(), prevReleased, "released is monotonic non-decreasing across the walk");
            assertLe(vesting.released(), GENESIS, "released never exceeds genesis at any step");
            prevReleased = vesting.released();
        }
        assertEq(vesting.released(), GENESIS, "the full genesis is released by the horizon, no dust stranded");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // (c) TREASURY-EOA: prove no remaining consumer of the treasury address needs it to be a
    //     contract. RevenueDistributor books the 25% leg as a PULL balance keyed by the treasury
    //     address; a plain code-less EOA can pull it. Also covers the v3.1 no-staker fold (stakers'
    //     50% routed to the treasury EOA) — still fully pullable by the EOA.
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function test_treasuryEoa_pullsRevenueShare_noContractAssumption() public {
        address stakers = makeAddr("stakersEOA");
        address ops = makeAddr("opsEOA");
        RevenueDistributor dist = new RevenueDistributor(stakers, treasuryEoa, ops);

        MintableERC20 token = new MintableERC20("WETH", "WETH");
        uint256 amount = 1_000_000e18;
        token.mint(address(dist), amount); // caller transfers in first (R-22 guard)
        dist.notifyRevenue(address(token), amount);

        uint256 expectTreasury = (amount * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS;
        assertEq(dist.pending(treasuryEoa, address(token)), expectTreasury, "treasury 25% booked to the EOA key");
        assertEq(treasuryEoa.code.length, 0, "treasury is a plain EOA (no bytecode)");

        vm.prank(treasuryEoa);
        uint256 pulled = dist.pull(address(token));
        assertEq(pulled, expectTreasury, "EOA treasury pulled its 25% leg");
        assertEq(token.balanceOf(treasuryEoa), expectTreasury, "funds landed at the EOA");
    }

    function test_treasuryEoa_noStakerFold_pullable() public {
        address stakers = makeAddr("stakersEOA");
        address ops = makeAddr("opsEOA");
        RevenueDistributor dist = new RevenueDistributor(stakers, treasuryEoa, ops);

        MintableERC20 token = new MintableERC20("WETH", "WETH");
        uint256 amount = 1_000_000e18;
        token.mint(address(dist), amount);
        dist.notifyRevenueNoStakers(address(token), amount); // stakers' 50% folds into treasury

        uint256 toStakers = (amount * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS;
        uint256 toTreasury = (amount * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS;
        uint256 expectTreasury = toTreasury + toStakers; // fold
        assertEq(dist.pending(treasuryEoa, address(token)), expectTreasury, "folded 75% booked to the EOA");

        vm.prank(treasuryEoa);
        uint256 pulled = dist.pull(address(token));
        assertEq(pulled, expectTreasury, "EOA treasury pulled the folded 75% leg");
    }
}

/// @dev Beneficiary contract that attempts to re-enter GenesisVesting.claim() from the token's
///      transfer callback. The re-entrant call is wrapped in try/catch purely so the OUTER claim can
///      complete and the test can assert the inner attempt reverted (CEI protection) — a plain
///      un-caught re-entry would just revert the whole tx, which is also safe but harder to assert on.
contract ClaimReenterer is IReentrancyVictim {
    GenesisVesting public vesting;
    bool public innerReverted;
    bool internal armed;

    function set(GenesisVesting v) external {
        vesting = v;
    }

    function arm() external {
        armed = true;
    }

    function trigger() external returns (uint256) {
        return vesting.claim();
    }

    function onTokenReceived() external override {
        if (!armed) return;
        armed = false; // one-shot: never recurse past the first re-entry attempt
        try vesting.claim() {
            innerReverted = false;
        } catch {
            innerReverted = true;
        }
    }
}
