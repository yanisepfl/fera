// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {EmissionsController} from "../../src/EmissionsController.sol";
import {FeraToken} from "../../src/FeraToken.sol";
import {IFeraToken} from "../../src/interfaces/IFeraToken.sol";
import {MintableERC20} from "../utils/Mocks.sol";

/// @title FormalMoneyInvariants — symbolic (Halmos) proofs of the core money-path invariants.
/// @notice Each `check_*` function is a HALMOS symbolic property: Halmos treats every function
///         argument as a fresh symbolic value and PROVES the assertion for ALL inputs (no fuzz
///         sampling — an SMT `unsat` on the negation is a proof). Run:
///
///             pip install halmos            # brings its own z3
///             cd contracts
///             halmos --contract FormalMoneyInvariants          # all check_* below
///             halmos --function check_INV10_splitConservesExactly   # one property
///
///         Config lives in `contracts/halmos.toml`. These proofs were WRITTEN + type-checked +
///         empirically exercised under `forge test` (the `testFuzz_*` wrappers run the SAME math
///         512×/prop here); the SYMBOLIC (all-inputs) proof is run with the command above — Halmos
///         was not installed in the authoring sandbox, so the symbolic pass is delivered-to-run.
///
///         Scope rationale: the invariants proven here are the ones whose violation MOVES MONEY and
///         whose arithmetic is self-contained (splits, conservation ceilings, share round-trips,
///         reward solvency). FeraVault/FeraHook value moves route through v4 `poolManager.unlock`
///         external calls + inline assembly, which symbolic engines model as havoc — those paths are
///         covered by the Foundry SMTChecker profile (small contracts) + the stateful invariant
///         suites (`ShareNavInvariant`, `VaultNavSequence`) instead.
///
///         Mapping to MASTER_SPEC §2:
///           INV-16  deposit→withdraw round-trip never returns > deposit   → check_INV16_roundTripNeverProfits
///           INV-9   esFERA: claimed + exited ≤ amount, always              → check_INV9_claimedPlusExitedLeAmount
///           INV-9   forfeit split conserves (burn+stakers+rev == haircut)  → check_INV9_forfeitSplitConserves
///           INV-7   emitted ≤ min(cap, β·rev)                              → check_INV7_emittedWithinEnvelope
///           INV-10  RevenueDistributor split exact 50/25/25, no dust       → check_INV10_splitConservesExactly
///           AnchorStaking per-token solvency (Σowed ≤ Σpulled)             → check_stakingSolvency_reward_leq_pulled
contract FormalMoneyInvariants is Test {
    using Math for uint256;

    /// @dev Upper bound that keeps `x * BPS` (≤ 2.5e4) inside uint256 while staying ~1e14× above the
    ///      900M·1e18 max FERA supply — so the proof is over the entire economically-reachable domain,
    ///      not a toy slice. Above this the contract's own `x*bps` would 0.8-revert (unreachable path).
    uint256 internal constant DOMAIN = 2 ** 200;

    // ════════════════════════════════════════════════════════════════════════════════════════════
    // INV-10 — RevenueDistributor 50/25/25, exact, no dust escapes (MASTER_SPEC §2 INV-10)
    // Mirrors RevenueDistributor.notifyRevenue (src/RevenueDistributor.sol:52-58) EXACTLY, then proves
    // conservation on the LIVE contract's post-state (pending mapping), symbolically over `amount`.
    // ════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev Pure re-derivation of the split (mirrors lines 52-54) for the fuzz wrapper + lemma.
    function _split(uint256 amount) internal pure returns (uint256 s, uint256 t, uint256 o) {
        s = (amount * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS;
        t = (amount * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS;
        o = amount - s - t; // remainder-to-ops ⇒ no dust
    }

    /// HALMOS: for ALL amount, the LIVE RevenueDistributor books exactly `amount` across the three
    /// recipients with the exact 50/25/25 shares and ZERO dust (Σpending == amount, INV-10).
    function check_INV10_splitConservesExactly(uint256 amount) public {
        vm.assume(amount > 0 && amount < DOMAIN);
        address s = makeAddr("stakers");
        address t = makeAddr("treasury");
        address o = makeAddr("ops");

        RevenueDistributor dist = new RevenueDistributor(s, t, o);
        MintableERC20 token = new MintableERC20("USD", "USD");
        token.mint(address(dist), amount); // caller transfers in first (R-22 balance-delta guard)
        dist.notifyRevenue(address(token), amount);

        (uint256 es, uint256 et, uint256 eo) = _split(amount);
        assertEq(dist.pending(s, address(token)), es, "stakers share != 50%");
        assertEq(dist.pending(t, address(token)), et, "treasury share != 25%");
        assertEq(dist.pending(o, address(token)), eo, "ops share != 25%");
        // Conservation: nothing created, nothing lost — every wei is accounted (INV-10, no dust).
        assertEq(
            dist.pending(s, address(token)) + dist.pending(t, address(token)) + dist.pending(o, address(token)),
            amount,
            "revenue split leaked dust"
        );
    }

    function testFuzz_INV10_splitConservesExactly(uint256 amount) public {
        amount = bound(amount, 1, DOMAIN - 1);
        (uint256 s, uint256 t, uint256 o) = _split(amount);
        assertEq(s + t + o, amount, "split leaked");
        assertEq(s, amount / 2, "not 50%");
        assertEq(t, amount / 4, "not 25%");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════
    // INV-9 — esFERA forfeit split conserves: burned + toStakers + toRevenue == haircut, 1/3 each
    // Mirrors EsFera._routeForfeit (src/EsFera.sol:117-120). Pure lemma, all inputs.
    // ════════════════════════════════════════════════════════════════════════════════════════════

    function _forfeit(uint256 haircut) internal pure returns (uint256 toStakers, uint256 toRevenue, uint256 burned) {
        toStakers = haircut / FeraConstants.FORFEIT_PARTS;
        toRevenue = haircut / FeraConstants.FORFEIT_PARTS;
        burned = haircut - toStakers - toRevenue; // remainder-to-burn ⇒ exact conservation
    }

    /// HALMOS: for ALL haircut, the forfeit split conserves value exactly (INV-9), the burn leg takes
    /// the ≤2-wei rounding remainder (never over-pays), and each payout leg is ≤ ⌈haircut/3⌉.
    function check_INV9_forfeitSplitConserves(uint256 haircut) public pure {
        (uint256 toStakers, uint256 toRevenue, uint256 burned) = _forfeit(haircut);
        assert(toStakers + toRevenue + burned == haircut); // no wei created/destroyed
        assert(toStakers == toRevenue); // symmetric thirds
        assert(burned >= toStakers); // remainder-to-burn ⇒ burn ≥ each third (dust destroyed, not paid)
        assert(burned - toStakers <= 2); // ≤2-wei rounding remainder only
    }

    function testFuzz_INV9_forfeitSplitConserves(uint256 haircut) public pure {
        (uint256 s, uint256 r, uint256 b) = _forfeit(haircut);
        assert(s + r + b == haircut);
        assert(b - s <= 2);
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════
    // INV-9 / R-20 — esFERA grant conservation: claimed + exited ≤ amount, ALWAYS.
    // The heart of R-20: `_unlockedOf` caps the claimable ceiling at `amount - exited` (src/EsFera.sol:
    // 175-179) and `_consumeLocked` bounds `exited` by the locked principal, so the total released
    // (claimed + exited) can never exceed the immutable grant `amount`. Proven symbolically here.
    // ════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev Mirror of EsFera._unlockedOf: claimable = min(vestedByTime, amount - exited).
    function _unlocked(uint256 amount, uint256 exited, uint256 vestedByTime) internal pure returns (uint256) {
        uint256 cap = amount - exited; // exited ≤ amount by construction (see assume)
        return vestedByTime < cap ? vestedByTime : cap;
    }

    /// HALMOS: over ALL (amount, exited, vestedByTime) reachable states — `exited ≤ amount` (enforced
    /// by _consumeLocked) and `vestedByTime ≤ amount` (schedule caps at amount) — the released
    /// principal `claimed + exited` NEVER exceeds the grant. This is the exact R-20 conservation
    /// ceiling the old (amount-shrinking) code violated. `claimed` here is the maximal claim
    /// `_unlockedOf` allows given `exited` already recorded.
    function check_INV9_claimedPlusExitedLeAmount(uint256 amount, uint256 exited, uint256 vestedByTime) public view {
        vm.assume(exited <= amount); // _consumeLocked never records more exit than locked principal
        vm.assume(vestedByTime <= amount); // _vestedByTime caps at amount past endTs
        uint256 claimed = _unlocked(amount, exited, vestedByTime);
        assert(claimed + exited <= amount); // R-20 / INV-9 conservation ceiling
    }

    function testFuzz_INV9_claimedPlusExitedLeAmount(uint256 amount, uint256 exited, uint256 vestedByTime) public pure {
        exited = bound(exited, 0, amount);
        vestedByTime = bound(vestedByTime, 0, amount);
        uint256 claimed = _unlocked(amount, exited, vestedByTime);
        assert(claimed + exited <= amount);
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════
    // INV-7 — Epoch emission ≤ min( cap(t), β × revenueValuedInFera ). (MASTER_SPEC §2 INV-7)
    // Proven on the LIVE EmissionsController: after a successful finalizeEpoch the emitted amount is
    // bounded by BOTH arms of the envelope. The guard is EmissionsController.finalizeEpoch:107-109.
    // ════════════════════════════════════════════════════════════════════════════════════════════

    /// HALMOS: for ALL (requested, revenue), a finalizeEpoch that SUCCEEDS emits an amount that is
    /// ≤ marginal cap AND ≤ β·revenue/1e18 — i.e. the INV-7 envelope can never be exceeded, and the
    /// `beta*revenue/1e18` math has no bypass. (Reverting paths — requested over-envelope — carry no
    /// state change and are correctly excluded.)
    function check_INV7_emittedWithinEnvelope(uint256 requested, uint256 revenue) public {
        // < 2^180 so `beta·revenue` (beta ≤ 0.9e18 ≈ 2^60) stays inside uint256; ~1e30× above real revenue.
        vm.assume(revenue < 2 ** 180);
        // Fresh controller with THIS as keeper + timelock so we can finalize.
        FeraToken fera = new FeraToken(address(this));
        address esFeraSink = makeAddr("esFeraSink");
        EmissionsController ec =
            new EmissionsController(IFeraToken(address(fera)), esFeraSink, address(this), address(this));
        fera.setEmissionsController(address(ec)); // grant mint authority (owner == this)

        uint256 e = 0;
        vm.warp(ec.epochEnd(e) + 1); // epoch clock satisfied

        // Independently recompute the INV-7 envelope from the contract's own state.
        uint256 cap = ec.capAt(ec.epochEnd(e));
        uint256 marginalCap = cap > ec.totalEmitted() ? cap - ec.totalEmitted() : 0;
        uint256 revenueBound = (ec.beta() * revenue) / 1e18;

        uint256 emitted = ec.finalizeEpoch(e, requested, revenue, 1e18); // reverts if over-envelope
        assertLe(emitted, marginalCap, "emitted > cap arm (INV-7)");
        assertLe(emitted, revenueBound, "emitted > beta*revenue arm (INV-7)");
        assertEq(ec.emittedOf(e), emitted, "emittedOf mismatch");
    }

    function testFuzz_INV7_emittedWithinEnvelope(uint256 requested, uint256 revenue) public {
        revenue = bound(revenue, 0, 2 ** 180 - 1);
        FeraToken fera = new FeraToken(address(this));
        EmissionsController ec = new EmissionsController(
            IFeraToken(address(fera)), makeAddr("sink"), address(this), address(this)
        );
        fera.setEmissionsController(address(ec));
        vm.warp(ec.epochEnd(0) + 1);
        uint256 cap = ec.capAt(ec.epochEnd(0));
        uint256 revenueBound = (ec.beta() * revenue) / 1e18;
        uint256 envelope = cap < revenueBound ? cap : revenueBound;
        requested = bound(requested, 0, envelope);
        if (requested == 0) return; // finalize with 0 is legal but nothing to assert on the arms
        uint256 emitted = ec.finalizeEpoch(0, requested, revenue, 1e18);
        assertLe(emitted, cap, "cap arm");
        assertLe(emitted, revenueBound, "rev arm");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════
    // INV-16 — deposit→withdraw round-trip never returns MORE than deposited (share-NAV completeness).
    // The Vault mints `shares = mulDiv(depositValue, totalShares, navBefore)` (floor) and redeems
    // `out = mulDiv(shares, navAfter, totalSharesAfter)` (floor). Proven: out ≤ deposit for ALL states.
    // This is the arithmetic core of R-18/INV-16 (src/FeraVault.sol _mintNonFirst / _cbWithdraw).
    // ════════════════════════════════════════════════════════════════════════════════════════════

    /// HALMOS: for ALL (deposit, totalShares, nav) with nav>0 ∧ totalShares>0, minting shares against
    /// the FULL NAV and immediately redeeming them returns ≤ deposit — a depositor can NEVER extract
    /// more than they put in (no value minted from nothing; existing holders are never skimmed).
    function check_INV16_roundTripNeverProfits(uint256 deposit, uint256 totalShares, uint256 nav) public view {
        // Bound < 2^118 so the worst case (nav==1) `shares = deposit·totalShares` ≤ 2^236 stays inside
        // uint256 (mulDiv's final result must fit) and `totalShares + shares` cannot overflow. 2^118 ≈
        // 3e35 is ~1e8× above the 900M·1e18 max NAV, so the domain is exhaustive in practice.
        vm.assume(nav > 0 && nav < 2 ** 118);
        vm.assume(totalShares > 0 && totalShares < 2 ** 118);
        vm.assume(deposit > 0 && deposit < 2 ** 118);

        uint256 shares = deposit.mulDiv(totalShares, nav); // mint (floor) — INV-16 full-NAV pricing
        uint256 navAfter = nav + deposit; // NAV grows by the deposit value
        uint256 sharesAfter = totalShares + shares; // supply grows by minted shares
        uint256 out = shares.mulDiv(navAfter, sharesAfter); // redeem (floor)
        assert(out <= deposit); // INV-16: round-trip never profits
    }

    function testFuzz_INV16_roundTripNeverProfits(uint256 deposit, uint256 totalShares, uint256 nav) public pure {
        nav = bound(nav, 1, 2 ** 118 - 1);
        totalShares = bound(totalShares, 1, 2 ** 118 - 1);
        deposit = bound(deposit, 1, 2 ** 118 - 1);
        uint256 shares = deposit.mulDiv(totalShares, nav);
        uint256 out = shares.mulDiv(nav + deposit, totalShares + shares);
        assert(out <= deposit);
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════
    // AnchorStaking per-token solvency — Σ(reward credited) ≤ pulled, ALWAYS (R-21 / DF-8).
    // With the DF-8 ceil-debt baseline, the sum of what stakers can claim from one harvest of `pulled`
    // never exceeds `pulled` (so a claim can never revert for insufficient balance and no reward is
    // invented). Proven for the 2-staker case — precisely the config where the pre-fix FLOOR debt
    // over-distributed by up to (nStakers-1) wei. Mirrors _syncDebt (ceil) + _settle (floor).
    // ════════════════════════════════════════════════════════════════════════════════════════════

    uint256 internal constant PREC = 1e18; // ACC_PRECISION

    /// HALMOS: two stakers with shares (s1,s2) present when `pulled` is harvested (accPerShare rises
    /// by d = ⌊pulled·PREC/total⌋); each debt baseline is CEIL, each accrual is FLOOR. The sum of the
    /// two credits never exceeds `pulled` — per-token solvency holds for ALL (s1,s2,pulled,accBase).
    function check_stakingSolvency_reward_leq_pulled(uint256 s1, uint256 s2, uint256 pulled, uint256 accBase)
        public
        view
    {
        vm.assume(s1 > 0 && s2 > 0);
        vm.assume(s1 < 2 ** 80 && s2 < 2 ** 80); // > 1e24, above any real stake; keeps sums in-range
        vm.assume(pulled < 2 ** 80);
        vm.assume(accBase < 2 ** 160); // accPerShare baseline (scaled by PREC)

        uint256 total = s1 + s2;
        uint256 d = pulled.mulDiv(PREC, total); // accPerShare increment from this harvest (floor)
        uint256 acc = accBase + d; // accPerShare after harvest

        // Each staker synced their debt at `accBase` (ceil), accrues at `acc` (floor):
        uint256 credit1 = _credit(s1, acc, accBase);
        uint256 credit2 = _credit(s2, acc, accBase);

        assert(credit1 + credit2 <= pulled); // Σ owed ≤ pulled — solvency, no reward invented
    }

    /// @dev Mirror of _settle (floor accrual) minus _syncDebt (ceil baseline) for one staker.
    function _credit(uint256 shares, uint256 acc, uint256 accBase) internal pure returns (uint256) {
        uint256 accrued = shares.mulDiv(acc, PREC); // _settle: floor
        uint256 debt = shares.mulDiv(accBase, PREC, Math.Rounding.Ceil); // _syncDebt DF-8: ceil
        return accrued > debt ? accrued - debt : 0;
    }

    function testFuzz_stakingSolvency_reward_leq_pulled(uint256 s1, uint256 s2, uint256 pulled, uint256 accBase)
        public
        pure
    {
        s1 = bound(s1, 1, 2 ** 80 - 1);
        s2 = bound(s2, 1, 2 ** 80 - 1);
        pulled = bound(pulled, 0, 2 ** 80 - 1);
        accBase = bound(accBase, 0, 2 ** 160 - 1);
        uint256 total = s1 + s2;
        uint256 d = pulled.mulDiv(PREC, total);
        uint256 acc = accBase + d;
        assert(_credit(s1, acc, accBase) + _credit(s2, acc, accBase) <= pulled);
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════
    // withdrawSingle ≤ pro-rata NAV (Attack-4 / VAULT_STRATEGY_V2.md §4 — AGENT-6 re-audit extension).
    // The withdrawer takes their floored pro-rata IN-KIND slice (out0,out1), then self-swaps the unwanted
    // leg into `tokenOut`. A pool swap only LOSES value (taker receives ≤ spot). Proven: the single-token
    // output valued at spot is NEVER more than the in-kind slice value (≤ +1 wei of floor rounding) — a
    // single-coin exit can never over-pay vs a plain in-kind `withdraw`, so no value is extracted from the
    // remaining holders. Mirrors src/FeraVault.sol::_cbWithdrawSingle (floored slice + value-losing swap).
    // ════════════════════════════════════════════════════════════════════════════════════════════

    /// HALMOS: price P = pNum/pDen (token1 per token0). `got` is the fair-or-worse self-swap output — a
    /// pool swap of `leg` never yields more numeraire than `leg` at spot. For ALL slices/prices/outputs,
    /// value(single-token output) ≤ value(in-kind slice) + 1 wei. `wantToken0` selects the leg swapped.
    function check_withdrawSingle_leProRata(
        uint256 out0,
        uint256 out1,
        uint256 got,
        uint256 pNum,
        uint256 pDen,
        bool wantToken0
    ) public pure {
        vm.assume(pNum > 0 && pDen > 0 && pNum < 2 ** 128 && pDen < 2 ** 128);
        vm.assume(out0 < 2 ** 120 && out1 < 2 ** 120 && got < 2 ** 120);

        uint256 proRata = out0.mulDiv(pNum, pDen) + out1; // in-kind slice, in token1 numeraire
        if (wantToken0) {
            // swap out1 → token0 (fair-or-worse: the token0 received is worth ≤ the token1 leg spent).
            vm.assume(got.mulDiv(pNum, pDen) <= out1);
            uint256 single = (out0 + got).mulDiv(pNum, pDen); // all token0, valued in token1
            assert(single <= proRata + 1); // +1: floor superadditivity, NOT a real over-payment
        } else {
            // swap out0 → token1 (fair-or-worse: the token1 received is worth ≤ the token0 leg spent).
            vm.assume(got <= out0.mulDiv(pNum, pDen));
            uint256 single = out1 + got; // all token1
            assert(single <= proRata);
        }
    }

    function testFuzz_withdrawSingle_leProRata(
        uint256 out0,
        uint256 out1,
        uint256 got,
        uint256 pNum,
        uint256 pDen,
        bool wantToken0
    ) public pure {
        pNum = bound(pNum, 1, 2 ** 128 - 1);
        pDen = bound(pDen, 1, 2 ** 128 - 1);
        out0 = bound(out0, 0, 2 ** 120 - 1);
        out1 = bound(out1, 0, 2 ** 120 - 1);
        uint256 proRata = out0.mulDiv(pNum, pDen) + out1;
        if (wantToken0) {
            got = bound(got, 0, 2 ** 120 - 1);
            vm.assume(got.mulDiv(pNum, pDen) <= out1);
            assert((out0 + got).mulDiv(pNum, pDen) <= proRata + 1);
        } else {
            uint256 cap = out0.mulDiv(pNum, pDen);
            got = bound(got, 0, cap);
            assert(out1 + got <= proRata);
        }
    }
}
