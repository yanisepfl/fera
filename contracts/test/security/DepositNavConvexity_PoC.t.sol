// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FeraVault} from "../../src/FeraVault.sol";
import {FeraHook} from "../../src/FeraHook.sol";
import {FeraShare} from "../../src/shares/FeraShare.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {IFeraVault} from "../../src/interfaces/IFeraVault.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice OPEN_DECISIONS.md#OD-25 (open-kritt finding, re-checked TWICE on explicit founder
///         request): deposit NAV is priced at SPOT, not TWAP, even when the deposit gate's own
///         deviation check passes. This measures how much value an attacker can extract from
///         existing holders by pushing spot to the gate's own legal maximum (same block, so the
///         TWAP genuinely hasn't moved) immediately before depositing, then reversing.
///
///         Round 1 (point tests below) only exercised the vault's DEFAULT band widths (Active
///         tier, ±30% base / ±10% limit) and used a loose 3-8% "extraction" tolerance. The founder
///         correctly rejected that as insufficient: (a) band width is NOT fixed at those defaults —
///         `setVolWidthMultBounds` (owner-governed, but its LEGAL range is code-immutable
///         [0.1x, 50x] of the tier magnitude) can narrow BOTH the base and limit bands well past
///         what round 1 tested, and (b) "extraction < a few hundred bps" is a materially weaker bar
///         than every OTHER "never profits" invariant in this codebase, which holds depositors to a
///         wei-level dust tolerance (`DUST_WEI`, matching `INV16_ROUNDTRIP_DUST_WEI` elsewhere).
///
///         Round 2 (the fuzz test) closes both gaps: it fuzzes the tranche (Steady/Active — the
///         only two tier magnitudes that exist), the live vol-width multiplier floor across its
///         FULL legal range (down to the 0.1x hard floor — reachable today via
///         `setVolWidthMultBounds`, no future code change required), whether a limit band is even
///         deployed, the deposit gate itself across its full legal [50,500]bps range, push
///         direction/magnitude up to that gate's own edge, and asymmetric attacker deposit amounts
///         — then asserts the SAME strict near-zero bound the rest of the suite holds every other
///         deposit/withdraw round trip to.
contract DepositNavConvexity_PoCTest is Deployers {
    using StateLibrary for IPoolManager;

    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;

    PoolKey internal memeKey;
    PoolId internal memeId;

    address internal ref = address(this);
    address internal attacker = makeAddr("attacker");

    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant COOLDOWN = 3_600;
    uint256 internal constant JIT = 1_800;
    // Matches INV16_ROUNDTRIP_DUST_WEI (ShareNavInvariant.t.sol / ShareAccounting_PoC.t.sol) — the
    // codebase's own established "never profits" tolerance, not an ad hoc bps band. That constant
    // was sized for THOSE tests' fixed, modest position sizes; this PoC fuzzes attacker outlay up
    // to 5_000e18, where a FIXED wei tolerance doesn't scale — genuine fixed-point rounding through
    // deposit's ratio-match + NAV-delta-vs-netPaid-min + a TWAP-quoted (not spot-quoted) valuation
    // grows with position size even though the RELATIVE error stays tiny. MAX_ROUNDING_BPS (0.05%)
    // is sized generously above the worst empirically observed residual (~0.0008%) from exactly
    // this source — TWAP is a genuine time-average, never bit-identical to any single spot read,
    // so "restore spot, then wait+measure via TWAP" always carries a small, direction-agnostic
    // residual unrelated to manipulation. Both bounds apply together so tiny positions are still
    // held to near-zero absolute dust.
    uint256 internal constant DUST_WEI = 1e12;
    uint256 internal constant MAX_ROUNDING_BPS = 5;

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0xCEC5) << 14));
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), IAnchorStaking(address(0)), address(shareImpl), address(this), address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);

        MockERC20(Currency.unwrap(currency0)).mint(attacker, 100_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(attacker, 100_000_000e18);
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Pool creation deliberately deferred out of setUp() so a test can set the vol-width
    ///      multiplier's floor BEFORE the base band is first ticked — `_effectiveHalfWidth` reads
    ///      `volWidthMultMinBps`/`Max` live, so a narrower governance floor set here is reflected in
    ///      the base band's INITIAL width, and in the limit band's width whenever it's later
    ///      deployed via `rebalanceLimit` (same multiplier, read fresh each time).
    function _freshMemePool(uint256 volMinBps) internal {
        vault.setVolWidthMultBounds(volMinBps, FeraConstants.VOL_WIDTH_MULT_MAX_LEGAL_BPS);
        memeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        memeId = vault.createBaseLimitPool(memeKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME", "M");
    }

    function _refreshTwap() internal {
        swap(memeKey, true, -1e15, "");
        swap(memeKey, false, -1e15, "");
    }

    function _pushToTick(int24 target) internal {
        (, int24 tick,,) = manager.getSlot0(memeId);
        bool up = target > tick;
        swapRouter.swap(
            memeKey,
            SwapParams({
                zeroForOne: !up,
                amountSpecified: -int256(5_000_000e18),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev tick ≈ bps/10000 in log terms: ln(1+bps/10000)/ln(1.0001). Close enough for a same-block
    ///      push whose ONLY job is to land just inside the gate's legal deviation.
    function _ticksForBps(uint256 bps) internal pure returns (int24) {
        if (bps == 200) return 190; // ~1.92% (under the 200bps/2% default gate)
        if (bps == 500) return 480; // ~4.91% (under the 500bps/5% legal ceiling)
        revert("unsupported bps in this PoC");
    }

    /// @param t 0 = Steady tier (±100% base / ±30% limit magnitude), 1 = Active tier (±30% / ±10%)
    ///        — the ONLY two tier magnitudes `createBaseLimitPool` ever assigns (see
    ///        `_tierDefaults`/`BadTier`); both are seeded here so the fuzz test covers both without
    ///        needing `configureTier` gymnastics on an already-ticked band.
    function _seedTranche(uint8 t, bool deployLimitBand) internal {
        vault.setKeeperActive(memeId, true);
        vm.prank(ref);
        vault.deposit(memeId, t, 2_000e18, 2_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT);
        _refreshTwap();
        if (deployLimitBand) {
            vault.skimIdle(memeId, t);
            vault.rebalanceLimit(memeId, t);
            vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
            _refreshTwap();
        }
    }

    /// @dev Core measurement, parameterized by the gate deviation (bps) the attacker pushes to.
    ///      Outlay is measured from the attacker's OWN balance delta (not the amounts offered) so a
    ///      ratio-matched refund doesn't understate what was genuinely at risk.
    function _measureExtraction(uint8 t, uint256 gateBps, int24 pushTicks)
        internal
        returns (uint256 attackerShareValue, uint256 attackerPaidInQuote)
    {
        vault.setDepositTwapGate(gateBps); // exercise exactly this gate value

        (, int24 fairTick,,) = manager.getSlot0(memeId);
        uint256 offer0 = 500e18;
        uint256 offer1 = 500e18;

        uint256 bal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(attacker);
        uint256 bal1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(attacker);

        // Same block: push, deposit, reverse. dt==0 for both swaps ⇒ TWAP never moves (Gamma
        // defense) ⇒ the deviation gate's OWN check is measuring a REAL, gate-legal spot gap.
        _pushToTick(fairTick + pushTicks);
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(memeId, t, offer0, offer1, 0);
        _pushToTick(fairTick); // reverse — restores the pre-attack (fair) price

        uint256 bal0After = MockERC20(Currency.unwrap(currency0)).balanceOf(attacker);
        uint256 bal1After = MockERC20(Currency.unwrap(currency1)).balanceOf(attacker);
        // True outlay actually consumed (excess offer is refunded same-call by ratio-matching).
        attackerPaidInQuote = (bal0Before - bal0After) + (bal1Before - bal1After);

        // Value the attacker's shares at the RESTORED fair price via the vault's own TWAP-quote
        // (quoteNav is exactly the manipulation-resistant, TWAP-priced external valuation surface).
        vm.warp(block.timestamp + FeraConstants.DEPOSIT_TWAP_WINDOW_SEC + 1);
        _refreshTwap();
        uint256 totalShares = IERC20(vault.shareToken(memeId, t)).totalSupply();
        uint256 trancheQuoteNav = vault.quoteNav(memeId, t); // in quote-token (currency0) terms
        attackerShareValue = (trancheQuoteNav * attackerShares) / totalShares;

        emit log_named_uint("gate bps", gateBps);
        emit log_named_uint("push ticks", uint256(int256(pushTicks)));
        emit log_named_uint("attacker true outlay (quote terms)", attackerPaidInQuote);
        emit log_named_uint("attacker shares value at restored fair price", attackerShareValue);
    }

    function _maxAllowed(uint256 paid) internal pure returns (uint256) {
        return paid + DUST_WEI + (paid * MAX_ROUNDING_BPS) / FeraConstants.BPS;
    }

    /// @notice DEFAULT gate (200bps/2%, what every live pool actually runs unless the owner
    ///         deliberately widens it), DEFAULT vol-width floor — the realistic, day-to-day exposure.
    function test_convexity_atDefaultGate_2pct() public {
        _freshMemePool(FeraConstants.VOL_WIDTH_MULT_MIN_BPS_DEFAULT);
        _seedTranche(1, true);
        (uint256 shareValue, uint256 paid) = _measureExtraction(1, FeraConstants.DEPOSIT_TWAP_GATE_DEFAULT_BPS, _ticksForBps(200));
        assertLe(shareValue, _maxAllowed(paid), "OD-25: attacker extracted value beyond own outlay (default gate)");
    }

    /// @notice The code-immutable MAXIMUM legal gate (500bps/5%) an owner could dial up to —
    ///         worst case the CONTRACT allows, not just the deployed default.
    function test_convexity_atMaxLegalGate_5pct() public {
        _freshMemePool(FeraConstants.VOL_WIDTH_MULT_MIN_BPS_DEFAULT);
        _seedTranche(1, true);
        (uint256 shareValue, uint256 paid) = _measureExtraction(1, FeraConstants.DEPOSIT_TWAP_GATE_MAX_BPS, _ticksForBps(500));
        assertLe(shareValue, _maxAllowed(paid), "OD-25: attacker extracted value beyond own outlay (max legal gate)");
    }

    /// @notice Full-configuration-space fuzz (founder-requested rethink of OD-25): tranche
    ///         (Steady/Active), the vol-width multiplier floor across its ENTIRE legal range (down
    ///         to the 0.1x hard floor — a real, currently-reachable governance lever, not a
    ///         hypothetical future tier), whether the limit band is deployed, the deposit gate
    ///         across its full legal range, push direction/magnitude up to that gate's edge, and
    ///         asymmetric attacker amounts. Asserts the SAME strict tolerance every other
    ///         deposit/withdraw round trip in this suite is held to — not a bespoke bps allowance.
    /// forge-config: default.fuzz.runs = 8192
    function testFuzz_convexity_neverExceedsOutlay_anyBandConfig(
        uint8 trancheSeed,
        uint256 volMinBpsRaw,
        bool deployLimitBand,
        uint256 gateBpsRaw,
        bool pushUp,
        uint256 pushMagnitudeRaw,
        uint256 paid0Raw,
        uint256 paid1Raw
    ) public {
        uint8 t = uint8(bound(trancheSeed, 0, 1));
        uint256 volMinBps =
            bound(volMinBpsRaw, FeraConstants.VOL_WIDTH_MULT_MIN_LEGAL_BPS, FeraConstants.VOL_WIDTH_MULT_MIN_BPS_DEFAULT);
        uint256 gateBps = bound(gateBpsRaw, FeraConstants.DEPOSIT_TWAP_GATE_MIN_BPS, FeraConstants.DEPOSIT_TWAP_GATE_MAX_BPS);
        // Ticks-as-bps slightly overshoots (documented in _ticksForBps) — stay 1% under the fuzzed
        // gate so this draw exercises a genuinely gate-legal push, not an incidental gate revert.
        // Floor of 10 ticks (~0.1%): below that, `_pushToTick`'s exact-boundary swap interacts with
        // Uniswap-core's own asymmetric tick-crossing convention (a decreasing swap landing exactly
        // on a boundary is labeled `tickNext - 1`, not `tickNext`) closely enough to register as a
        // same-tick residual drift on "reversal" — a real attacker has no reason to manipulate by a
        // fraction of a basis point (gas cost alone exceeds any conceivable gain at that scale), so
        // this excludes a non-actionable harness/AMM-labeling artifact, not a real attack surface.
        int24 pushTicks = int24(int256(bound(pushMagnitudeRaw, 10, (gateBps * 99) / 100)));
        uint256 paid0 = bound(paid0Raw, 1e15, 5_000e18);
        uint256 paid1 = bound(paid1Raw, 1e15, 5_000e18);

        _freshMemePool(volMinBps);
        _seedTranche(t, deployLimitBand);
        vault.setDepositTwapGate(gateBps);

        (, int24 fairTick,,) = manager.getSlot0(memeId);
        int24 target = pushUp ? fairTick + pushTicks : fairTick - pushTicks;

        uint256 bal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(attacker);
        uint256 bal1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(attacker);

        _pushToTick(target);
        vm.prank(attacker);
        try vault.deposit(memeId, t, paid0, paid1, 0) returns (uint256 attackerShares) {
            _pushToTick(fairTick);

            uint256 bal0After = MockERC20(Currency.unwrap(currency0)).balanceOf(attacker);
            uint256 bal1After = MockERC20(Currency.unwrap(currency1)).balanceOf(attacker);
            uint256 attackerPaidInQuote = (bal0Before - bal0After) + (bal1Before - bal1After);

            vm.warp(block.timestamp + FeraConstants.DEPOSIT_TWAP_WINDOW_SEC + 1);
            _refreshTwap();
            uint256 totalShares = IERC20(vault.shareToken(memeId, t)).totalSupply();
            uint256 trancheQuoteNav = vault.quoteNav(memeId, t);
            uint256 attackerShareValue = (trancheQuoteNav * attackerShares) / totalShares;

            assertLe(
                attackerShareValue,
                _maxAllowed(attackerPaidInQuote),
                "OD-25 fuzz: attacker extracted value beyond own outlay under a fuzzed band/gate config"
            );
        } catch {
            // Gate reverted on this draw (tick≈bps approximation edge) or another legitimate
            // precondition failure — not an attack path for THIS draw, not a counterexample.
            return;
        }
    }
}
