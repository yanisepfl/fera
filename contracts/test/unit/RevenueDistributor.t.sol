// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {MintableERC20, ReturnsFalseERC20, CallbackERC20, PullReenterer, LyingBalanceERC20} from "../utils/Mocks.sol";

/// @notice INV-10 — RevenueDistributor splits every inflow EXACTLY 50/25/25 (stakers/treasury/ops);
///         no rounding dust escapes accounting. Plus malicious-ERC20 policy (SafeERC20) and CEI.
contract RevenueDistributorTest is Test {
    RevenueDistributor internal dist;
    MintableERC20 internal token;

    address internal stakers = makeAddr("stakers");
    address internal treasury = makeAddr("treasury");
    address internal ops = makeAddr("ops");

    function setUp() public {
        dist = new RevenueDistributor(stakers, treasury, ops);
        token = new MintableERC20("USD", "USD");
    }

    function test_constructor_rejectsZeroAddress() public {
        vm.expectRevert(IRevenueDistributor.ZeroAddress.selector);
        new RevenueDistributor(address(0), treasury, ops);
    }

    /// INV-10: for ANY amount, the three shares sum to EXACTLY `amount` (remainder-to-ops, no dust),
    /// and stakers=50%, treasury=25% (floors), ops=remainder (≥25%).
    function testFuzz_split_conservesExactly(uint256 amount) public {
        amount = bound(amount, 0, 1e30);
        token.mint(address(dist), amount);
        dist.notifyRevenue(address(token), amount);

        uint256 s = dist.pending(stakers, address(token));
        uint256 t = dist.pending(treasury, address(token));
        uint256 o = dist.pending(ops, address(token));

        // Exact conservation — the whole invariant (INV-10).
        assertEq(s + t + o, amount, "dust escaped accounting");

        // Split shape: floors on stakers/treasury, remainder to ops.
        assertEq(s, (amount * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS, "stakers != 50%");
        assertEq(t, (amount * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS, "treasury != 25%");
        assertEq(o, amount - s - t, "ops != remainder");

        // ops carries at most 2 wei of rounding remainder over the nominal 25%.
        uint256 opsNominal = (amount * FeraConstants.REV_OPS_BPS) / FeraConstants.BPS;
        assertLe(o - opsNominal, 2, "ops remainder > 2 wei");
    }

    /// Accumulation across many inflows still conserves exactly.
    function test_split_accumulates() public {
        uint256[3] memory amts = [uint256(1), 7, 999_999_999];
        uint256 total;
        for (uint256 i; i < amts.length; ++i) {
            token.mint(address(dist), amts[i]);
            dist.notifyRevenue(address(token), amts[i]);
            total += amts[i];
        }
        uint256 sum = dist.pending(stakers, address(token)) + dist.pending(treasury, address(token))
            + dist.pending(ops, address(token));
        assertEq(sum, total, "accumulated dust");
    }

    function test_notify_zeroIsNoop() public {
        dist.notifyRevenue(address(token), 0);
        assertEq(dist.pending(stakers, address(token)), 0);
    }

    /// Pull moves funds and zeroes pending (CEI). Second pull reverts NothingToPull.
    function test_pull_movesFundsAndClears() public {
        token.mint(address(dist), 1000);
        dist.notifyRevenue(address(token), 1000);

        vm.prank(stakers);
        uint256 got = dist.pull(address(token));
        assertEq(got, 500, "stakers pull != 50%");
        assertEq(token.balanceOf(stakers), 500);
        assertEq(dist.pending(stakers, address(token)), 0);

        vm.prank(stakers);
        vm.expectRevert(IRevenueDistributor.NothingToPull.selector);
        dist.pull(address(token));
    }

    // ── R-22: balance-delta guard (unbacked credit → pull-DoS) ───────────────────────────────

    /// notifyRevenue with NO tokens transferred in MUST revert — pre-fix this inflated `_pending`
    /// above the real balance and permanently bricked pull (the transfer would always revert).
    function test_R22_notifyWithoutTransfer_reverts() public {
        vm.expectRevert(IRevenueDistributor.UnbackedRevenue.selector);
        dist.notifyRevenue(address(token), 1e30);
        assertEq(dist.pending(stakers, address(token)), 0, "pending inflated without funds");
    }

    /// Even after legitimate revenue, a follow-up over-credit beyond the delivered balance reverts.
    function test_R22_overCreditBeyondBalance_reverts() public {
        token.mint(address(dist), 1000);
        dist.notifyRevenue(address(token), 1000); // fully backed

        // No new transfer ⇒ any further credit is unbacked ⇒ revert (pending stays ≤ balance).
        vm.expectRevert(IRevenueDistributor.UnbackedRevenue.selector);
        dist.notifyRevenue(address(token), 1);
    }

    /// Invariant (fuzz): across arbitrary notify/pull sequences, Σpending is ALWAYS ≤ the real
    /// balance — so a pull can never revert for insufficient funds (INV-10 / R-22).
    function testFuzz_R22_pendingNeverExceedsBalance(uint256[8] memory amts, uint256 pullMask) public {
        for (uint256 i; i < amts.length; ++i) {
            uint256 amt = bound(amts[i], 0, 1e27);
            // Honest inflow: transfer first, then notify (what EsFera/Vault do).
            token.mint(address(dist), amt);
            dist.notifyRevenue(address(token), amt);

            // Occasionally a recipient pulls.
            if ((pullMask >> i) & 1 == 1) {
                address who = [stakers, treasury, ops][i % 3];
                if (dist.pending(who, address(token)) != 0) {
                    vm.prank(who);
                    dist.pull(address(token));
                }
            }

            uint256 sigmaPending = dist.pending(stakers, address(token))
                + dist.pending(treasury, address(token)) + dist.pending(ops, address(token));
            assertLe(sigmaPending, token.balanceOf(address(dist)), "sum(pending) exceeded real balance (R-22)");
        }
    }

    // ── OD-23: a fake token's fabricated credit must never contaminate a REAL token's accounting ──

    /// OPEN_DECISIONS.md#OD-23, "ACCEPTED, isolated per-token, no cross-contamination" — proven
    /// here rather than left as verbal reasoning. A throwaway token whose `balanceOf` always lies
    /// (reports an arbitrary large value with zero real backing) fools the R-22 guard for ITS OWN
    /// namespace, but `_pending`/`_accounted` are keyed per-token — fuzzes the fake token's lied
    /// balance and credited amount, a REAL token's own independent revenue amount, and the ORDER
    /// the two are notified in, and asserts the real token's pending balances are bit-for-bit
    /// unaffected by the fake credit, in either order.
    function testFuzz_OD23_fakeTokenCreditNeverContaminatesRealToken(
        uint256 fakeReportedBalance,
        uint256 fakeAmount,
        uint256 realAmount,
        bool fakeFirst
    ) public {
        // Capped at 1e30 (~1000x the entire 900M-FERA max supply at 18 decimals) — comfortably
        // beyond any real-world amount while staying well under the ~1.15e73 threshold where the
        // contract's OWN internal `amount * BPS` multiplication would overflow uint256 on its own
        // (a separate, already-accepted "checked-arith reverts on an astronomical, physically
        // unreachable input" class — see OPEN_DECISIONS.md#OD-16 — not what OD-23 is about).
        fakeReportedBalance = bound(fakeReportedBalance, 1, 1e30);
        fakeAmount = bound(fakeAmount, 1, fakeReportedBalance);
        realAmount = bound(realAmount, 1, 1e30);

        LyingBalanceERC20 fakeToken = new LyingBalanceERC20(fakeReportedBalance);

        if (fakeFirst) {
            dist.notifyRevenue(address(fakeToken), fakeAmount);
        }

        token.mint(address(dist), realAmount);
        dist.notifyRevenue(address(token), realAmount);

        if (!fakeFirst) {
            dist.notifyRevenue(address(fakeToken), fakeAmount);
        }

        (uint256 es, uint256 et, uint256 eo) = (
            (realAmount * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS,
            (realAmount * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS,
            realAmount - (realAmount * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS
                - (realAmount * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS
        );
        assertEq(dist.pending(stakers, address(token)), es, "fake credit contaminated real token (stakers)");
        assertEq(dist.pending(treasury, address(token)), et, "fake credit contaminated real token (treasury)");
        assertEq(dist.pending(ops, address(token)), eo, "fake credit contaminated real token (ops)");
        assertEq(
            dist.pending(stakers, address(token)) + dist.pending(treasury, address(token))
                + dist.pending(ops, address(token)),
            realAmount,
            "real token accounting no longer conserves exactly"
        );

        // And the fake token's OWN (fabricated) credit is real only within its own namespace —
        // pulling it is a hollow, self-contained event, not something that drains any real asset.
        uint256 fakeSum = dist.pending(stakers, address(fakeToken)) + dist.pending(treasury, address(fakeToken))
            + dist.pending(ops, address(fakeToken));
        assertEq(fakeSum, fakeAmount, "fake token's own split still conserves (isolated bookkeeping)");
    }

    // ── malicious-ERC20 policy ───────────────────────────────────────────────────────────────

    /// A "returns false" token must make pull revert (SafeERC20), never silently succeed.
    function test_malicious_returnsFalseToken_pullReverts() public {
        ReturnsFalseERC20 bad = new ReturnsFalseERC20();
        bad.mint(address(dist), 1000);
        dist.notifyRevenue(address(bad), 1000);

        vm.prank(stakers);
        vm.expectRevert(); // OZ SafeERC20 -> SafeERC20FailedOperation
        dist.pull(address(bad));
    }

    /// Reentrancy under CEI: a callback token that re-enters pull cannot double-withdraw — pending
    /// is zeroed before the transfer, so the re-entrant pull reverts NothingToPull and unwinds the
    /// whole attack (no theft, funds untouched).
    function test_reentrancy_pull_isCEISafe() public {
        CallbackERC20 cb = new CallbackERC20();

        // The RevenueDistributor is deployed AFTER the attacker; predict its address so the attacker
        // (which is the `stakers` recipient) can hold a reference to it (breaks the immutable cycle).
        address predictedDist = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        PullReenterer attacker = new PullReenterer(IRevenueDistributor(predictedDist), address(cb));
        RevenueDistributor d = new RevenueDistributor(address(attacker), treasury, ops);
        require(address(d) == predictedDist, "dist addr mismatch");

        cb.mint(address(d), 1000);
        d.notifyRevenue(address(cb), 1000);
        cb.setCallback(address(attacker), true);

        vm.expectRevert(IRevenueDistributor.NothingToPull.selector);
        attacker.attack();

        // No theft: distributor still holds the full balance (state rolled back).
        assertEq(cb.balanceOf(address(d)), 1000, "funds moved despite revert");
        assertEq(cb.balanceOf(address(attacker)), 0, "attacker gained funds");
    }
}
