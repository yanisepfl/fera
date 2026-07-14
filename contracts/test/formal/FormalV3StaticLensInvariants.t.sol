// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {MintableERC20} from "../utils/Mocks.sol";

/// @title FormalV3StaticLensInvariants — symbolic (Halmos) proofs of the TWO highest-value NEW v3
///        money-path invariants, added by the static-analysis + formal spot-check auditor.
/// @notice NEW FILE (does not edit the shared `FormalMoneyInvariants.t.sol`, to avoid collisions
///         with the other parallel v3 auditors). Same convention as that file:
///         each `check_*` is a HALMOS symbolic property (every argument is a fresh symbolic value,
///         proved for ALL inputs via SMT `unsat`-on-negation), and each has a `testFuzz_*` twin that
///         exercises the IDENTICAL math under `forge test` fuzzing. Halmos is NOT installed in this
///         sandbox, so the SYMBOLIC pass is DELIVERED-TO-RUN:
///
///             pip install halmos
///             cd contracts
///             halmos --contract FormalV3StaticLensInvariants
///
///         The `testFuzz_*` twins DID run here (512×/prop) and pass — so the arithmetic core is
///         empirically verified even before the symbolic pass.
///
///         Coverage (contracts/VAULT_STRATEGY_V3.md):
///           §4  IL-AWARE STAGED RECENTER — the per-call self-swap notional is capped to `ilBudget`,
///               so the worst-case realized IL of that swap is ≤ ilBudget REGARDLESS of price-gap
///               size. Mirrors `FeraVault._balanceReserve` (cap-then-convert) + `selfSwap`'s budget
///               check.                                        → check_ilCap_notionalNeverExceedsBudget
///           §9  UNIFIED FEE-ROUTING, no-staker reroute — when `totalStaked()==0` the stakers' 50%
///               leg folds into treasury and the split STILL conserves `amount` exactly (no dust,
///               nothing minted). Proven on the LIVE `RevenueDistributor.notifyRevenueNoStakers`.
///                                                            → check_noStakerRouting_conservesExactly
contract FormalV3StaticLensInvariants is Test {
    using Math for uint256;

    uint256 internal constant Q96 = 1 << 96;

    // ════════════════════════════════════════════════════════════════════════════════════════════
    // §4 — IL-AWARE STAGED RECENTER: capped self-swap notional ≤ ilBudget (⇒ worst-case IL ≤ ilBudget)
    //
    // The provable §4 bound, restated: a swap can NEVER lose more value than the value it puts at risk
    // (amountOut ≥ 0 always), so if the NOTIONAL (token1-equivalent value) actually swapped is capped
    // to ≤ ilBudget, the realized IL of that ONE swap is ≤ ilBudget — no matter how large the base
    // band's one-sidedness (price gap) was. This proves the CAP-AND-CONVERT arithmetic of
    // `FeraVault._balanceReserve` (token0-surplus branch — the symmetric token1 branch is identical by
    // relabeling): the amount fed to `_doSelfSwap`, re-valued at the SAME price, never exceeds the
    // budget even after the two floor round-trips (value→amount→value) and the reserve clamp.
    //
    // Mirrors src/FeraVault.sol#_balanceReserve:
    //     val0       = mulDiv(reserve0, priceX96, 2^96)          // reserve0 valued in token1
    //     idealVal   = (val0 - reserve1) / 2                     // the ideal 50/50-balancing notional
    //     boundedVal = min(idealVal, ilBudget)                   // §4 cap
    //     amt0       = mulDiv(boundedVal, 2^96, priceX96)        // notional → token0 amount (floor)
    //     amt0       = min(amt0, reserve0)                       // never spend more than reserve
    // The value truly put at risk is `amt0` re-valued at the same price; we prove it ≤ ilBudget.
    // ════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev Re-derivation of `_balanceReserve`'s cap-and-convert (token0-surplus branch), returning
    ///      the token0 amount actually handed to the bounded self-swap.
    function _cappedAmt0(uint256 reserve0, uint256 reserve1, uint256 priceX96, uint256 ilBudget)
        internal
        pure
        returns (uint256 amt0)
    {
        uint256 val0 = FullMath.mulDiv(reserve0, priceX96, Q96);
        // token0-surplus branch precondition (the caller only enters this branch when val0 > reserve1).
        uint256 idealVal = (val0 - reserve1) / 2;
        uint256 boundedVal = idealVal > ilBudget ? ilBudget : idealVal;
        amt0 = FullMath.mulDiv(boundedVal, Q96, priceX96);
        if (amt0 > reserve0) amt0 = reserve0;
    }

    /// HALMOS: for ALL (reserve0, reserve1, priceX96, ilBudget) in the token0-surplus branch, the
    /// token1-NOTIONAL of the amount `_balanceReserve` actually swaps — re-valued at the SAME price —
    /// is ≤ ilBudget. Because a swap's realized loss ≤ its notional-at-risk (output ≥ 0), this proves
    /// the §4 claim that ONE call's IL is bounded by ilBudget INDEPENDENT of the price gap.
    function check_ilCap_notionalNeverExceedsBudget(
        uint256 reserve0,
        uint256 reserve1,
        uint256 priceX96,
        uint256 ilBudget
    ) public pure {
        // Domain: ~1e8-1e14x above every real magnitude (reserves ≪ 2^112 tokens; a v4 priceX96 for
        // any realistic pair sits well inside [2^48, 2^144]; ilBudget = 3%·NAV ≪ 2^160). Bounds chosen
        // so every FullMath.mulDiv quotient provably fits uint256 (no spurious revert), while the
        // proven inequality (notional ≤ boundedVal ≤ ilBudget) holds over the ENTIRE domain.
        vm.assume(reserve0 < 2 ** 112 && reserve1 < 2 ** 112);
        vm.assume(priceX96 >= 2 ** 48 && priceX96 < 2 ** 144);
        vm.assume(ilBudget < 2 ** 160);

        uint256 val0 = FullMath.mulDiv(reserve0, priceX96, Q96);
        vm.assume(val0 > reserve1); // token0-surplus branch

        uint256 amt0 = _cappedAmt0(reserve0, reserve1, priceX96, ilBudget);
        // amt0 ≤ reserve0 < 2^112 and priceX96 < 2^144 ⇒ notional < 2^160 (fits; no revert).
        uint256 notional = FullMath.mulDiv(amt0, priceX96, Q96);

        // Core §4 bound: the value actually put at risk by this ONE self-swap ≤ the IL budget.
        assert(notional <= ilBudget);
        // Therefore the worst-case realized IL of the swap (loss = notional − amountOut ≤ notional)
        // is ≤ ilBudget as well — the "provably bounded regardless of price gap" property.
    }

    function testFuzz_ilCap_notionalNeverExceedsBudget(
        uint256 reserve0,
        uint256 reserve1,
        uint256 priceX96,
        uint256 ilBudget
    ) public pure {
        reserve0 = bound(reserve0, 0, 2 ** 112 - 1);
        reserve1 = bound(reserve1, 0, 2 ** 112 - 1);
        priceX96 = bound(priceX96, 2 ** 48, 2 ** 144 - 1);
        ilBudget = bound(ilBudget, 0, 2 ** 160 - 1);
        uint256 val0 = FullMath.mulDiv(reserve0, priceX96, Q96);
        vm.assume(val0 > reserve1);
        uint256 amt0 = _cappedAmt0(reserve0, reserve1, priceX96, ilBudget);
        assert(FullMath.mulDiv(amt0, priceX96, Q96) <= ilBudget);
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════
    // §9 — UNIFIED FEE-ROUTING, no-staker reroute conserves exactly (INV-10 preserved under the new
    // `notifyRevenueNoStakers` branch). When AnchorStaking.totalStaked()==0, the stakers' 50% leg is
    // folded into treasury; we prove the LIVE RevenueDistributor still books EXACTLY `amount` across
    // the recipients with ZERO dust — the v3.1 reroute never mints, loses, or strands a wei.
    // Mirrors src/RevenueDistributor.sol#_notify(stakersEligible=false).
    // ════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev < 2^200: keeps `amount * BPS` (≤ 2.5e4) inside uint256, ~1e14x above max FERA supply.
    uint256 internal constant DOMAIN = 2 ** 200;

    /// HALMOS: for ALL amount, `notifyRevenueNoStakers` credits stakers=0, treasury=50%+25%, ops=25%,
    /// summing to EXACTLY amount (no dust escapes — INV-10 holds under the reroute).
    function check_noStakerRouting_conservesExactly(uint256 amount) public {
        vm.assume(amount > 0 && amount < DOMAIN);
        address s = makeAddr("stakers");
        address t = makeAddr("treasury");
        address o = makeAddr("ops");

        RevenueDistributor dist = new RevenueDistributor(s, t, o);
        MintableERC20 token = new MintableERC20("USD", "USD");
        token.mint(address(dist), amount); // caller transfers in first (R-22 balance-delta guard)
        dist.notifyRevenueNoStakers(address(token), amount);

        uint256 sPart = (amount * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS;
        uint256 tPart = (amount * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS;
        uint256 oPart = amount - sPart - tPart;

        assertEq(dist.pending(s, address(token)), 0, "stakers must get 0 under no-staker routing");
        assertEq(dist.pending(t, address(token)), tPart + sPart, "treasury must absorb the stakers' leg");
        assertEq(dist.pending(o, address(token)), oPart, "ops share changed");
        // Conservation: every wei accounted, none created/lost (INV-10 under the v3.1 reroute).
        assertEq(
            dist.pending(s, address(token)) + dist.pending(t, address(token)) + dist.pending(o, address(token)),
            amount,
            "no-staker reroute leaked dust"
        );
    }

    function testFuzz_noStakerRouting_conservesExactly(uint256 amount) public {
        amount = bound(amount, 1, DOMAIN - 1);
        address s = makeAddr("stakers");
        address t = makeAddr("treasury");
        address o = makeAddr("ops");
        RevenueDistributor dist = new RevenueDistributor(s, t, o);
        MintableERC20 token = new MintableERC20("USD", "USD");
        token.mint(address(dist), amount);
        dist.notifyRevenueNoStakers(address(token), amount);
        uint256 sPart = (amount * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS;
        uint256 tPart = (amount * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS;
        uint256 oPart = amount - sPart - tPart;
        assertEq(dist.pending(s, address(token)), 0);
        assertEq(dist.pending(t, address(token)), tPart + sPart);
        assertEq(dist.pending(o, address(token)), oPart);
        assertEq(
            dist.pending(s, address(token)) + dist.pending(t, address(token)) + dist.pending(o, address(token)),
            amount
        );
    }
}
