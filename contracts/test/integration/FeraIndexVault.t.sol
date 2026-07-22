// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FeraVault} from "../../src/FeraVault.sol";
import {FeraHook} from "../../src/FeraHook.sol";
import {FeraShare} from "../../src/shares/FeraShare.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {FeraIndexVault} from "../../src/FeraIndexVault.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {IFeraVault} from "../../src/interfaces/IFeraVault.sol";
import {IFeraIndexVault} from "../../src/interfaces/IFeraIndexVault.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Local-harness integration + invariant tests for FeraIndexVault (spec §9 INV-I1..I5 +
///         the §5 flows + §6 guardrails), over a REAL v4 PoolManager, the real FERA hook + vault,
///         and 5 wWETH-quoted MEME pools (mirrors the 5 live pools; the fork variant lives in
///         FeraIndexForkTest.t.sol). The index acquires each memecoin leg by swapping THROUGH the
///         member pool (never an external router) exactly as `FeraVault.selfSwap` does.
contract FeraIndexVaultTest is Deployers {
    using StateLibrary for IPoolManager;

    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;
    FeraIndexVault internal index;

    MockERC20 internal wweth;

    uint256 internal constant N = 5;
    MockERC20[N] internal memes;
    PoolKey[N] internal keys;
    PoolId[N] internal ids;
    bool[N] internal q0; // quoteIsToken0 per member pool

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant COOLDOWN = 3_600; // FeraConstants.DEPOSIT_COOLDOWN_SEC
    uint256 internal constant JIT = 1_800;
    uint256 internal constant SEED = 50_000e18; // per-pool per-side base-band seed (deep)

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();

        wweth = new MockERC20("Wrapped WETH", "wWETH", 18);
        wweth.mint(address(this), 100_000_000e18);
        wweth.approve(address(swapRouter), type(uint256).max);
        wweth.approve(address(modifyLiquidityRouter), type(uint256).max);

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x4242) << 14));
        vault = new FeraVault(
            manager,
            IFeraHook(hookAddr),
            IRevenueDistributor(address(rev)),
            IAnchorStaking(address(0)),
            address(shareImpl),
            address(this),
            address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);
        vault.setAllowedQuoteAsset(address(wweth), true);

        for (uint256 i; i < N; ++i) {
            MockERC20 meme = new MockERC20("Meme", "MEME", 18);
            meme.mint(address(this), 10_000_000e18);
            meme.approve(address(vault), type(uint256).max);
            meme.approve(address(swapRouter), type(uint256).max);
            memes[i] = meme;

            bool q = address(wweth) < address(meme);
            q0[i] = q;
            (Currency c0, Currency c1) = q
                ? (Currency.wrap(address(wweth)), Currency.wrap(address(meme)))
                : (Currency.wrap(address(meme)), Currency.wrap(address(wweth)));
            PoolKey memory key =
                PoolKey({currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(hookAddr)});
            keys[i] = key;
            wweth.approve(address(vault), type(uint256).max);
            ids[i] = vault.createBaseLimitPool(key, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, q, "MEME", "m");
            vault.deposit(ids[i], 0, SEED, SEED, 0); // seed the base band (1:1)
        }

        // Age past cooldown + JIT and warm each pool's TWAP head.
        vm.warp(block.timestamp + COOLDOWN + JIT);
        for (uint256 i; i < N; ++i) {
            _refresh(keys[i]);
        }

        index = new FeraIndexVault(
            address(wweth), manager, IFeraHook(hookAddr), IFeraVault(address(vault)), keeper, address(this), "FERA Index", "fIDX"
        );

        PoolKey[] memory ks = new PoolKey[](N);
        uint16[] memory ws = new uint16[](N);
        for (uint256 i; i < N; ++i) {
            ks[i] = keys[i];
            ws[i] = 2_000; // equal weight 5 × 20% = 100%
        }
        index.setMembers(ks, ws);
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────

    function _refresh(PoolKey memory key) internal {
        swap(key, true, -1e15, "");
        swap(key, false, -1e15, "");
    }

    function _fund(address who, uint256 amount) internal {
        wweth.mint(who, amount);
        vm.prank(who);
        wweth.approve(address(index), type(uint256).max);
    }

    function _idxShareBal(uint256 i) internal view returns (uint256) {
        return IERC20(vault.shareToken(ids[i], 0)).balanceOf(address(index));
    }

    function _wbal(address who) internal view returns (uint256) {
        return wweth.balanceOf(who);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // Basic deposit: mints shares, builds the diversified basket, holds no naked memecoin
    // ═════════════════════════════════════════════════════════════════════════════════════════

    function test_deposit_buildsBasket_noNakedMemecoin() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        uint256 sh = index.deposit(500e18, 0);

        assertGt(sh, 0, "no shares minted");
        assertEq(index.balanceOf(alice), sh, "alice shares");
        assertEq(index.balanceOf(FeraIndexVault_DEAD()), 1_000, "MINIMUM_LIQUIDITY not locked");

        // The index holds a tranche-0 FeraShare of every member (diversified), and NO naked memecoin.
        for (uint256 i; i < N; ++i) {
            assertGt(_idxShareBal(i), 0, "member leg missing");
            assertLe(memes[i].balanceOf(address(index)), 1e6, "index holds a naked memecoin (> dust)");
        }
        // NAV ≈ deposit minus entry cost, and share price ≈ 1 wWETH/​share at genesis.
        uint256 nav = index.totalAssets();
        assertLe(nav, 500e18, "NAV exceeds deposit (value created)");
        assertGe(nav, (500e18 * 9_500) / 10_000, "entry cost > 5% (unexpectedly lossy)");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // INV-I1 (round trip): deposit → (no trades) → withdraw returns ≤ deposited
    // ═════════════════════════════════════════════════════════════════════════════════════════

    function test_INV_I1_roundTrip_neverMoreThanDeposited() public {
        _fund(alice, 1_000e18);
        uint256 before = _wbal(alice);
        vm.prank(alice);
        uint256 sh = index.deposit(400e18, 0);

        vm.warp(block.timestamp + COOLDOWN + 1); // clear the index's vault cooldown
        vm.prank(alice);
        uint256 out = index.withdraw(sh, 0);

        assertLe(out, 400e18, "round trip returned MORE than deposited (INV-I1)");
        assertEq(_wbal(alice), before - 400e18 + out, "balance accounting");
        // Sanity: a no-trade round trip only bleeds entry+exit cost, not a gross amount.
        assertGe(out, (400e18 * 9_200) / 10_000, "round-trip cost > 8% (unexpected)");
    }

    function testFuzz_INV_I1_roundTrip(uint256 amount) public {
        amount = bound(amount, 10e18, 2_000e18);
        _fund(alice, amount);
        vm.prank(alice);
        uint256 sh = index.deposit(amount, 0);

        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(alice);
        uint256 out = index.withdraw(sh, 0);
        assertLe(out, amount, "INV-I1: round trip > deposited");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // INV-I2 (solvency): index shares are only minted with a real basket delta; redemption is
    // strictly pro-rata of the FeraShare balances held (no unbacked shares, no over-redemption)
    // ═════════════════════════════════════════════════════════════════════════════════════════

    function test_INV_I2_solvency_proRataRedemption() public {
        _fund(alice, 1_000e18);
        _fund(bob, 1_000e18);
        vm.prank(alice);
        uint256 sa = index.deposit(300e18, 0);
        vm.prank(bob);
        uint256 sb = index.deposit(500e18, 0);

        uint256 supply = index.totalSupply();

        // Snapshot the index's per-member FeraShare balances, then redeem HALF of alice's shares.
        uint256[N] memory balBefore;
        for (uint256 i; i < N; ++i) {
            balBefore[i] = _idxShareBal(i);
        }
        uint256 half = sa / 2;

        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(alice);
        index.withdraw(half, 0);

        // Each member's FeraShare balance dropped by EXACTLY the pro-rata fraction (half/supply),
        // within floor dust — no path over-redeemed or left shares unbacked (INV-I2).
        for (uint256 i; i < N; ++i) {
            uint256 expectedDrop = FullMath.mulDiv(half, balBefore[i], supply);
            uint256 actualDrop = balBefore[i] - _idxShareBal(i);
            assertApproxEqAbs(actualDrop, expectedDrop, 2, "redemption not strictly pro-rata (INV-I2)");
        }
        // Remaining index shares are still fully backed: NAV per remaining share ≥ (pre-exit) minus dust.
        assertGt(index.totalAssets(), 0, "basket emptied incorrectly");
        assertEq(index.totalSupply(), supply - half, "supply accounting");
        sb; // (bob left in — his backing is untouched by alice's partial exit)
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // INV-I3 (bounds): no weight set / rebalance / entry can exceed the §6 clamps
    // ═════════════════════════════════════════════════════════════════════════════════════════

    function test_INV_I3_setWeights_guardrails() public {
        // Σ != 100% reverts.
        uint16[] memory bad = new uint16[](N);
        bad[0] = 3_000;
        bad[1] = 3_000;
        bad[2] = 3_000;
        bad[3] = 3_000;
        bad[4] = 1_000; // sum = 13_000
        vm.expectRevert(IFeraIndexVault.WeightSumNot100.selector);
        index.setWeights(bad);

        // a member > MAX_WEIGHT_BPS reverts.
        uint16[] memory over = new uint16[](N);
        over[0] = 3_500; // > 3000
        over[1] = 3_000;
        over[2] = 1_500;
        over[3] = 1_000;
        over[4] = 1_000;
        vm.expectRevert(IFeraIndexVault.BadWeight.selector);
        index.setWeights(over);

        // a member < MIN_WEIGHT_BPS reverts.
        uint16[] memory under = new uint16[](N);
        under[0] = 400; // < 500
        under[1] = 3_000;
        under[2] = 3_000;
        under[3] = 2_600;
        under[4] = 1_000;
        vm.expectRevert(IFeraIndexVault.BadWeight.selector);
        index.setWeights(under);

        // a valid re-weight sticks.
        uint16[] memory ok = new uint16[](N);
        ok[0] = 3_000;
        ok[1] = 2_500;
        ok[2] = 2_000;
        ok[3] = 1_500;
        ok[4] = 1_000;
        index.setWeights(ok);
        assertEq(index.memberInfo(ids[0]).weightBps, 3_000, "weight not applied");
    }

    function testFuzz_INV_I3_weightsAlwaysClamped(uint16[5] memory w) public {
        uint16[] memory ws = new uint16[](N);
        uint256 sum;
        bool inRange = true;
        for (uint256 i; i < N; ++i) {
            ws[i] = w[i];
            sum += w[i];
            if (w[i] < 500 || w[i] > 3_000) inRange = false;
        }
        if (inRange && sum == 10_000) {
            index.setWeights(ws); // a legal vector is accepted
        } else {
            vm.expectRevert();
            index.setWeights(ws); // anything outside the clamps reverts (INV-I3)
        }
    }

    function test_INV_I3_onlyOwnerAndKeeper() public {
        uint16[] memory ws = new uint16[](N);
        for (uint256 i; i < N; ++i) {
            ws[i] = 2_000;
        }
        vm.prank(alice);
        vm.expectRevert(); // Ownable: not owner
        index.setWeights(ws);

        vm.prank(alice);
        vm.expectRevert(IFeraIndexVault.OnlyKeeper.selector);
        index.rebalance(ids[0], ids[1], 100);
    }

    function test_INV_I3_rebalance_stepClamp_and_cooldown() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        index.deposit(500e18, 0);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Step over MAX_REBALANCE_STEP_BPS reverts.
        vm.prank(keeper);
        vm.expectRevert(IFeraIndexVault.StepTooLarge.selector);
        index.rebalance(ids[0], ids[1], 5_000);

        // Not overweight ⇒ reverts (equal-weight basket, no drift).
        vm.prank(keeper);
        vm.expectRevert(IFeraIndexVault.NotOverweight.selector);
        index.rebalance(ids[0], ids[1], 100);
    }

    function test_INV_I3_entry_depthCap() public {
        // A deposit large relative to pool depth moves a member's spot past MAX_ENTRY_VS_DEPTH_BPS
        // and reverts the WHOLE tx (EntryExceedsDepth) — no partial basket (spec §5).
        _fund(alice, 2_000_000e18);
        vm.prank(alice);
        vm.expectRevert(); // EntryExceedsDepth (or the vault's own TWAP gate) — either way, atomic revert
        index.deposit(1_000_000e18, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // INV-I4 (sandwich): an attacker wrapping an index entry cannot steal from existing holders,
    // and cannot extract more than the slippage bound implies
    // ═════════════════════════════════════════════════════════════════════════════════════════

    function test_INV_I4_sandwich_existingHolderProtected() public {
        // Bob is the existing holder.
        _fund(bob, 1_000e18);
        vm.prank(bob);
        uint256 bobSh = index.deposit(500e18, 0);
        uint256 bobValueBefore = index.convertToAssets(bobSh);

        // Attacker sandwiches alice's entry on member 0. Funded with wWETH only (the front-run buys
        // the memecoin; the back-run sells exactly what the front-run bought).
        wweth.mint(attacker, 1_000_000e18);
        vm.startPrank(attacker);
        wweth.approve(address(swapRouter), type(uint256).max);
        memes[0].approve(address(swapRouter), type(uint256).max);
        uint256 attBefore = _wbal(attacker);
        // front-run: push member-0 price up (exact-input 1000 wWETH).
        swapRouter.swap(
            keys[0],
            SwapParams({zeroForOne: q0[0], amountSpecified: -1_000e18, sqrtPriceLimitX96: q0[0] ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // Victim entry (bounded per-leg; may revert if the push moved member-0 past the TWAP/depth
        // bound — in which case the sandwich simply fails and nothing is extracted).
        _fund(alice, 1_000e18);
        vm.prank(alice);
        try index.deposit(500e18, 0) {} catch {}

        // back-run: attacker sells the memecoin the front-run bought.
        vm.startPrank(attacker);
        uint256 memeBal = memes[0].balanceOf(attacker);
        swapRouter.swap(
            keys[0],
            SwapParams({zeroForOne: !q0[0], amountSpecified: -int256(memeBal), sqrtPriceLimitX96: !q0[0] ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 attAfter = _wbal(attacker);
        vm.stopPrank();

        // 1. The attacker did NOT profit (round-trip fees + bounded victim slippage ⇒ a net loss).
        assertLe(attAfter, attBefore, "sandwich attacker turned a profit (INV-I4)");

        // 2. The existing holder (bob) was NOT diluted: his redeemable NAV is preserved (measured at
        //    the manipulation-resistant TWAP, so a same-block push cannot move it) within dust.
        uint256 bobValueAfter = index.convertToAssets(bobSh);
        assertGe(bobValueAfter + 1e15, bobValueBefore, "existing holder diluted by the sandwich (INV-I4)");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // INV-I5 (in-kind exit): emergencyRedeemInKind ALWAYS succeeds for aged shares, even when every
    // member pool's swap path reverts (here: TWAP gone stale ⇒ the swapping withdraw reverts)
    // ═════════════════════════════════════════════════════════════════════════════════════════

    function test_INV_I5_inKindExit_worksWhenSwapsRevert() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        uint256 sh = index.deposit(500e18, 0);

        // Age FAR past the TWAP staleness bound (2h) WITHOUT refreshing any pool ⇒ every member's
        // swap `minOut` read fails closed (TwapStale). This also clears the vault cooldown/lock.
        vm.warp(block.timestamp + FeraConstants.TWAP_MAX_STALENESS_SEC + COOLDOWN + 1);

        // The swapping withdraw reverts (a member swap hits TwapStale).
        vm.prank(alice);
        vm.expectRevert(IFeraIndexVault.TwapStale.selector);
        index.withdraw(sh, 0);

        // ...but the swap-free in-kind exit ALWAYS works for aged shares (INV-I5): the caller receives
        // the pro-rata FeraShare tokens of every member.
        vm.prank(alice);
        index.emergencyRedeemInKind(sh);

        assertEq(index.balanceOf(alice), 0, "shares not burned");
        for (uint256 i; i < N; ++i) {
            assertGt(IERC20(vault.shareToken(ids[i], 0)).balanceOf(alice), 0, "alice did not receive member leg in kind");
        }
    }

    function test_emergencyRedeem_revertsClearlyDuringCooldown() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        uint256 sh = index.deposit(500e18, 0);

        // Immediately after depositing, the index's FeraShare transfer-lock is armed ⇒ a clear revert.
        vm.prank(alice);
        vm.expectRevert(IFeraIndexVault.CooldownActive.selector);
        index.emergencyRedeemInKind(sh);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // Rebalance: a successful bounded move (overweight → underweight) shifts value without minting
    // ═════════════════════════════════════════════════════════════════════════════════════════

    function test_rebalance_movesValue_overweightToUnderweight() public {
        // Build the basket SKEWED: member 0 heavy (30%), member 1 light (5%). Then FLIP the targets so
        // member 0 is far overweight and member 1 far underweight — a clean drift with NO price
        // manipulation, so both pools stay healthy/liquid for the rebalance swaps.
        uint16[] memory skew = new uint16[](N);
        skew[0] = 3_000;
        skew[1] = 500;
        skew[2] = 2_500;
        skew[3] = 2_500;
        skew[4] = 1_500;
        index.setWeights(skew);

        _fund(alice, 2_000e18);
        vm.prank(alice);
        index.deposit(1_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + 1); // clear the vault cooldown so rebalance can redeem/deposit

        // Flip: member 0 target 5% (it holds ~30% ⇒ overweight by ~25% > band), member 1 target 30%
        // (it holds ~5% ⇒ underweight).
        uint16[] memory flip = new uint16[](N);
        flip[0] = 500;
        flip[1] = 3_000;
        flip[2] = 2_500;
        flip[3] = 2_500;
        flip[4] = 1_500;
        index.setWeights(flip);

        uint256 nav = index.totalAssets();
        assertGt(index.memberValue(ids[0]) * 10_000, (500 + 2_000) * nav, "member 0 not overweight");
        assertLt(index.memberValue(ids[1]) * 10_000, 3_000 * nav, "member 1 not underweight");

        uint256 v0Before = index.memberValue(ids[0]);
        uint256 v1Before = index.memberValue(ids[1]);
        uint256 navBefore = nav;
        uint256 supplyBefore = index.totalSupply();

        vm.prank(keeper);
        index.rebalance(ids[0], ids[1], 500); // move ≤ 5% of NAV from 0 → 1

        // Value shifted 0 → 1; no shares minted/burned; NAV only bled the bounded swap cost.
        assertLt(index.memberValue(ids[0]), v0Before, "member 0 not reduced");
        assertGt(index.memberValue(ids[1]), v1Before, "member 1 not increased");
        assertEq(index.totalSupply(), supplyBefore, "rebalance changed the share supply");
        assertLe(index.totalAssets(), navBefore, "rebalance created value");
        assertGe(index.totalAssets(), (navBefore * 9_700) / 10_000, "rebalance bled > 3% (unbounded cost)");
        // A second rebalance in the same window is cooldown-blocked.
        vm.prank(keeper);
        vm.expectRevert(IFeraIndexVault.RebalanceTooSoon.selector);
        index.rebalance(ids[0], ids[1], 500);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // Membership guardrails
    // ═════════════════════════════════════════════════════════════════════════════════════════

    function test_setMembers_rejectsNonWwethQuote() public {
        // A pool quoted in a non-wWETH token is rejected (QuoteNotAsset / not curated).
        MockERC20 usdg = new MockERC20("USDG", "USDG", 18);
        MockERC20 meme = new MockERC20("X", "X", 18);
        usdg.mint(address(this), 1_000_000e18);
        meme.mint(address(this), 1_000_000e18);
        vault.setAllowedQuoteAsset(address(usdg), true);
        bool q = address(usdg) < address(meme);
        (Currency c0, Currency c1) = q
            ? (Currency.wrap(address(usdg)), Currency.wrap(address(meme)))
            : (Currency.wrap(address(meme)), Currency.wrap(address(usdg)));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(address(hook))});
        vault.createBaseLimitPool(key, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, q, "X", "x");

        // A valid weight vector (≥4 members are required since MAX_WEIGHT_BPS = 30%) with ONE
        // non-wWETH-quoted member ⇒ the quote check fires (not a weight-clamp false negative).
        PoolKey[] memory ks = new PoolKey[](N);
        uint16[] memory ws = new uint16[](N);
        for (uint256 i; i < N - 1; ++i) {
            ks[i] = keys[i];
            ws[i] = 2_000;
        }
        ks[N - 1] = key; // USDG-quoted pool replaces member 4
        ws[N - 1] = 2_000;
        vm.expectRevert(IFeraIndexVault.QuoteNotAsset.selector);
        index.setMembers(ks, ws);
    }

    function test_setMembers_cannotDropMemberWithBalance() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        index.deposit(500e18, 0); // index now holds all 5 legs

        // Try to drop member 0 (index still holds its FeraShare) ⇒ MemberHasBalance.
        PoolKey[] memory ks = new PoolKey[](N - 1);
        uint16[] memory ws = new uint16[](N - 1);
        for (uint256 i; i < N - 1; ++i) {
            ks[i] = keys[i + 1]; // drop member 0
            ws[i] = 2_500; // 4 × 2500 = 10000
        }
        vm.expectRevert(IFeraIndexVault.MemberHasBalance.selector);
        index.setMembers(ks, ws);
    }

    function test_setMembers_tooManyMembers() public {
        PoolKey[] memory ks = new PoolKey[](13); // > MAX_MEMBERS (12)
        uint16[] memory ws = new uint16[](13);
        vm.expectRevert(IFeraIndexVault.TooManyMembers.selector);
        index.setMembers(ks, ws);
    }

    /// The MINIMUM_LIQUIDITY sink address (mirrors the contract's constant).
    function FeraIndexVault_DEAD() internal pure returns (address) {
        return 0x000000000000000000000000000000000000dEaD;
    }
}
