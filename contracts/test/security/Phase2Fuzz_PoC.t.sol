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
import {MockAggregatorV3, MockRebalanceVenue} from "../utils/Mocks.sol";

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

/// @title Phase2Fuzz_PoC
/// @notice Property/fuzz suite for the PHASE-2 vault surface (commits 3c67ac4 keeper-only swaps,
///         9db7def TWAP-quote NAV + ERC-4626 pricing on shares, f1e4630 pause freezes strategy):
///
///          P1  convertToAssets/convertToShares round-trip never INFLATES and loses at most the
///              floor-rounding bound (S/T+2 or T/S+2) — for fuzzed share/asset amounts + deposits.
///          P2  quoteNav is monotonic non-decreasing in deposits and never reverts for a live tranche.
///          P3  totalAssets()==quoteNav, pricePerShare()==convertToAssets(1e18),
///              convertToAssets(totalSupply)==totalAssets, asset()==quoteAsset (fuzzed deposits).
///          P4  A non-keeper caller can NEVER drive a swap: selfSwap / rebalanceViaVenue /
///              rebalanceBase(useSelfSwap=true) always revert OnlyKeeper (any fuzzed caller/args).
///          P5  The swap-FREE paths (rebalanceLimit / rebalanceBase(useSelfSwap=false)) NEVER revert
///              OnlyKeeper for a random caller (stay permissionless).
///          P6  A withdraw after the cooldown returns pro-rata IN-KIND (both legs conserved to the
///              tranche's actual token holdings) and is UNAFFECTED by the TWAP-NAV (quoteNav).
///
///         Harness modeled on test/integration/BaseLimitStrategy.t.sol / test/unit/VaultAdmin.t.sol.
contract Phase2FuzzTest is Deployers {
    using StateLibrary for IPoolManager;

    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;
    MockAggregatorV3 internal feed;
    MockRebalanceVenue internal venue;

    PoolKey internal memeKey;
    PoolId internal memeId;

    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant COOLDOWN = 3_600; // DEPOSIT_COOLDOWN_SEC (anti-JIT)
    uint256 internal constant JIT = 1_800;
    uint32 internal constant TWAP_WINDOW = 600; // DEPOSIT_TWAP_WINDOW_SEC

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));
        feed = new MockAggregatorV3(8);
        feed.set(1e8, block.timestamp);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x7A22) << 14));
        // keeper == owner == this test contract.
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

        memeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        // quoteIsToken0 = true ⇒ quoteNav is denominated in token0 (exercises VaultMath._valueInToken0).
        memeId = vault.createBaseLimitPool(memeKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME-BL", "mBL");

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);

        venue = new MockRebalanceVenue();
        MockERC20(Currency.unwrap(currency0)).transfer(address(venue), 100_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(address(venue), 100_000e18);
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────
    function _bal(address who) internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(Currency.unwrap(currency0)).balanceOf(who);
        b1 = IERC20(Currency.unwrap(currency1)).balanceOf(who);
    }

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(currency0)).transfer(who, 20_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(who, 20_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _seedMeme() internal {
        vault.deposit(memeId, 0, 1_000e18, 1_000e18, 0);
        vm.warp(block.timestamp + COOLDOWN + JIT);
        _refreshTwap(memeKey);
    }

    /// A tiny symmetric swap to keep the TWAP head fresh after a warp (REC-9 fail-closed avoidance).
    function _refreshTwap(PoolKey memory key) internal {
        swap(key, true, -1e15, "");
        swap(key, false, -1e15, "");
    }

    /// Push spot to a target tick with a bounded-price swap.
    function _pushToTick(PoolKey memory key, int24 target) internal {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        if (tick == target) return;
        bool up = target > tick;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !up,
                amountSpecified: -int256(5_000_000e18),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// First 4 bytes of revert returndata (0x0 for empty/success).
    function _sel(bytes memory data) internal pure returns (bytes4 s) {
        if (data.length >= 4) {
            assembly {
                s := mload(add(data, 0x20))
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // P1 — convert round-trip is ~identity (never inflates; loss bounded by the floor-rounding term)
    // ═════════════════════════════════════════════════════════════════════════════════════════
    function testFuzz_convertRoundTrip(uint256 d0, uint256 d1, uint256 sharesIn, uint256 assetsIn) public {
        d0 = bound(d0, 1e18, 100_000e18);
        d1 = bound(d1, 1e18, 100_000e18);
        vault.deposit(memeId, 0, d0, d1, 0);
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _refreshTwap(memeKey);

        FeraShare share = FeraShare(vault.shareToken(memeId, 0));
        uint256 S = share.totalSupply();
        uint256 T = share.totalAssets();
        assertGt(S, 0, "no supply");
        assertGt(T, 0, "no assets");

        // shares -> assets -> shares : never inflates; loss <= S/T + 2 (proved from floor bounds).
        sharesIn = bound(sharesIn, 0, S);
        uint256 aOut = share.convertToAssets(sharesIn);
        uint256 backShares = share.convertToShares(aOut);
        assertLe(backShares, sharesIn, "share round-trip INFLATED shares");
        assertLe(sharesIn - backShares, S / T + 2, "share round-trip loss exceeds rounding bound");

        // assets -> shares -> assets : never inflates; loss <= T/S + 2.
        assetsIn = bound(assetsIn, 0, T);
        uint256 sOut = share.convertToShares(assetsIn);
        uint256 backAssets = share.convertToAssets(sOut);
        assertLe(backAssets, assetsIn, "asset round-trip INFLATED assets");
        assertLe(assetsIn - backAssets, T / S + 2, "asset round-trip loss exceeds rounding bound");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // P2 — quoteNav monotonic non-decreasing in deposits, and never reverts for a live tranche
    // ═════════════════════════════════════════════════════════════════════════════════════════
    function testFuzz_quoteNavMonotonicInDeposits(uint256 d0, uint256 d1) public {
        _seedMeme();
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _refreshTwap(memeKey);

        uint256 navBefore = vault.quoteNav(memeId, 0); // live tranche: must not revert
        assertGt(navBefore, 0, "seeded tranche NAV should be positive");

        d0 = bound(d0, 1e18, 50_000e18);
        d1 = bound(d1, 1e18, 50_000e18);
        vault.deposit(memeId, 0, d0, d1, 0); // adds liquidity (no swap ⇒ price unchanged)

        uint256 navAfter = vault.quoteNav(memeId, 0);
        assertGe(navAfter, navBefore, "quoteNav DECREASED after a deposit (must be non-decreasing)");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // P3 — the ERC-4626 pricing surface is internally consistent
    // ═════════════════════════════════════════════════════════════════════════════════════════
    function testFuzz_pricingSurfaceConsistency(uint256 d0, uint256 d1) public {
        d0 = bound(d0, 1e18, 100_000e18);
        d1 = bound(d1, 1e18, 100_000e18);
        vault.deposit(memeId, 0, d0, d1, 0);
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _refreshTwap(memeKey);

        FeraShare share = FeraShare(vault.shareToken(memeId, 0));
        assertEq(share.totalAssets(), vault.quoteNav(memeId, 0), "totalAssets != quoteNav");
        assertEq(share.asset(), vault.quoteAsset(memeId), "asset() != quoteAsset");
        assertEq(share.pricePerShare(), share.convertToAssets(1e18), "pricePerShare != convertToAssets(1e18)");
        // convertToAssets(totalSupply) == mulDiv(S,T,S) == T exactly.
        assertEq(share.convertToAssets(share.totalSupply()), share.totalAssets(), "convertToAssets(supply) != totalAssets");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // P4 — a non-keeper caller can NEVER drive a swap (always OnlyKeeper), for any fuzzed args
    // ═════════════════════════════════════════════════════════════════════════════════════════
    function testFuzz_nonKeeperCannotDriveSwaps(address caller, uint8 tRaw, bool zeroForOne, uint256 amountIn) public {
        vm.assume(caller != address(this)); // address(this) is the keeper
        vm.assume(caller != address(0));
        uint8 t = uint8(bound(uint256(tRaw), 0, 1));
        amountIn = bound(amountIn, 0, 1_000e18);

        // selfSwap — onlyKeeper is the FIRST modifier ⇒ reverts before any state read, any args.
        vm.prank(caller);
        (bool ok1, bytes memory r1) = address(vault).call(abi.encodeCall(vault.selfSwap, (memeId, t, zeroForOne, amountIn)));
        assertFalse(ok1, "non-keeper selfSwap succeeded");
        assertEq(_sel(r1), IFeraVault.OnlyKeeper.selector, "selfSwap: expected OnlyKeeper");

        // rebalanceViaVenue — onlyKeeper.
        vm.prank(caller);
        (bool ok2, bytes memory r2) =
            address(vault).call(abi.encodeCall(vault.rebalanceViaVenue, (memeId, t, address(venue), zeroForOne, amountIn)));
        assertFalse(ok2, "non-keeper rebalanceViaVenue succeeded");
        assertEq(_sel(r2), IFeraVault.OnlyKeeper.selector, "rebalanceViaVenue: expected OnlyKeeper");

        // rebalanceBase(useSelfSwap=true) — inline keeper check (reached for a valid base-limit tranche).
        vm.prank(caller);
        (bool ok3, bytes memory r3) = address(vault).call(abi.encodeCall(vault.rebalanceBase, (memeId, t, true)));
        assertFalse(ok3, "non-keeper rebalanceBase(useSelfSwap=true) succeeded");
        assertEq(_sel(r3), IFeraVault.OnlyKeeper.selector, "rebalanceBase(true): expected OnlyKeeper");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // P5 — v3.4: the swap-FREE strategy paths are ALSO keeper-only (founder decision — zero grief
    // surface; even a bounded action leaves an adversary the choice of WHEN it fires). A non-keeper
    // ALWAYS reverts OnlyKeeper; the keeper positive-control still works within unchanged bounds.
    // ═════════════════════════════════════════════════════════════════════════════════════════
    function testFuzz_nonKeeperCannotDriveSwapFreeRebalances(address caller, uint8 tRaw) public {
        vm.assume(caller != address(this));
        vm.assume(caller != address(0));
        uint8 t = uint8(bound(uint256(tRaw), 0, 1));
        _seedMeme();

        // rebalanceLimit — the keeper gate is the FIRST modifier: always OnlyKeeper for a non-keeper.
        vm.prank(caller);
        (, bytes memory r1) = address(vault).call(abi.encodeCall(vault.rebalanceLimit, (memeId, t)));
        assertEq(_sel(r1), IFeraVault.OnlyKeeper.selector, "rebalanceLimit: expected OnlyKeeper for a non-keeper");

        // rebalanceBase(useSelfSwap=false) — same: always OnlyKeeper for a non-keeper.
        vm.prank(caller);
        (, bytes memory r2) = address(vault).call(abi.encodeCall(vault.rebalanceBase, (memeId, t, false)));
        assertEq(_sel(r2), IFeraVault.OnlyKeeper.selector, "rebalanceBase(false): expected OnlyKeeper for a non-keeper");
    }

    /// Positive control: the KEEPER can drive the swap-free limit deploy; a rando cannot.
    function test_keeperDrivesSwapFreeLimit_randoCannot() public {
        address rando = makeAddr("rando");
        _seedMeme();
        vault.skimIdle(memeId, 0);
        uint256 before = vault.bandCount(memeId, 0);
        vm.prank(rando);
        vm.expectRevert(IFeraVault.OnlyKeeper.selector);
        vault.rebalanceLimit(memeId, 0);
        vault.rebalanceLimit(memeId, 0); // keeper == this test contract
        assertEq(vault.bandCount(memeId, 0), before + 1, "keeper could not deploy the swap-free limit");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // P6 — withdraw is pro-rata IN-KIND (both legs, split by SHARE ratio) and UNAFFECTED by TWAP-NAV
    //
    // Two holders exit in the same block: alice for her slice, then bob for 100% of the remainder.
    // In-kind pro-rata ⇒ each leg splits by the share ratio: a0/b0 == a1/b1 == aliceSh/bobSh, i.e.
    //   a0*bobSh == b0*aliceSh  and  a1*bobSh == b1*aliceSh   (within a few wei of floor dust).
    // This is impossible if withdrawal were priced off the single quote-NAV number, and the identity
    // is immune to fee-accrual timing (fees accrue pro-rata too) — a far more robust invariant than
    // reconciling against a hand-rolled holdings proxy. quoteNav is driven far via a price push first.
    // ═════════════════════════════════════════════════════════════════════════════════════════
    function testFuzz_withdrawIsProRataInKind_notQuoteNavPriced(
        uint256 dA0,
        uint256 dA1,
        uint256 dB0,
        uint256 dB1,
        uint256 pushSeed
    ) public {
        dA0 = bound(dA0, 100e18, 8_000e18);
        dA1 = bound(dA1, 100e18, 8_000e18);
        dB0 = bound(dB0, 100e18, 8_000e18);
        dB1 = bound(dB1, 100e18, 8_000e18);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _fund(alice);
        _fund(bob);

        vm.prank(alice);
        uint256 aliceSh = vault.deposit(memeId, 0, dA0, dA1, 0);
        vm.prank(bob);
        uint256 bobSh = vault.deposit(memeId, 0, dB0, dB1, 0);
        assertGt(aliceSh, 0, "alice got no shares");
        assertGt(bobSh, 0, "bob got no shares");

        // Drive spot (hence the TWAP-priced quoteNav) away from the deposit level; a modest bounded
        // move keeps the wide Steady base straddling so both legs stay represented in-kind.
        int24 target = int24(int256(bound(pushSeed, 0, 600))) - 300;
        _pushToTick(memeKey, target);
        _refreshTwap(memeKey);

        // quoteNav is a single QUOTE-denominated number (TWAP-priced). The withdrawal below is a raw
        // two-token in-kind payout — it must NOT be a function of this number.
        uint256 navQuote = vault.quoteNav(memeId, 0);
        assertGt(navQuote, 0, "live tranche quoteNav positive");

        // Past the anti-JIT cooldown, both exit in the SAME block (no price move between them).
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(alice);
        (uint256 a0, uint256 a1) = vault.withdraw(memeId, 0, aliceSh, 0, 0);
        vm.prank(bob);
        (uint256 b0, uint256 b1) = vault.withdraw(memeId, 0, bobSh, 0, 0);

        // Pro-rata IN-KIND on BOTH legs: outputs split by the SHARE ratio, not by the quote NAV.
        assertApproxEqRel(a0 * bobSh, b0 * aliceSh, 1e15, "token0 leg not pro-rata to shares");
        assertApproxEqRel(a1 * bobSh, b1 * aliceSh, 1e15, "token1 leg not pro-rata to shares");
        // Genuine two-token exit (not a single-number quote payout).
        assertGt(a0, 0, "alice token0 leg missing");
        assertGt(a1, 0, "alice token1 leg missing");
        assertGt(b0, 0, "bob token0 leg missing");
        assertGt(b1, 0, "bob token1 leg missing");
    }
}
