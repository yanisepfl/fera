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
import {MockAggregatorV3} from "../utils/Mocks.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {QW} from "../utils/QW.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice AGENT-6 RE-AUDIT — stateful NAV-conservation invariant for the v2 BASE + LIMIT + IDLE
///         surface (VAULT_STRATEGY_V2.md §7 follow-up). A bounded, guarded action sequence drives the
///         NEW keeper + user paths — skimIdle / rebalanceLimit / selfSwap / withdrawSingle — interleaved
///         with foreign deposit/withdraw and time warps, then reconciles:
///
///           (A) NO OVER-EXTRACTION (INV-16 / Attack-5): foreigners who churn through the base+limit
///               paths can never withdraw more value than they deposited (a swap only loses value; the
///               loss stays inside the vault with the remaining holders — it is never minted from nothing).
///           (B) NON-DILUTION: a refHolder who seeded both tranches recovers ~its full deposit after any
///               interleaving of foreign churn + keeper rebalancing (bounded self-swap slippage only).
///
///         Design (mirrors VaultNavSequence): the VAULT is the SOLE LP and every keeper self-swap is
///         TINY, so the pool spot stays pinned at the 1:1 init — token0+token1 is a faithful NAV measure
///         and self-swap value impact is internal (stays with the vault). rebalanceBase is exercised as
///         a handler action (gate-rejected near spot; its self-swap SUCCESS path is proven in
///         test/security/BaseLimitReaudit_PoC.t.sol::test_BUG1_...). A bounded action array (not
///         StdInvariant) keeps each run a short deterministic sequence — CI-safe, TWAP never goes stale
///         mid-run. Stressed at the [fuzz].runs=512 setting (foundry.toml).
contract BaseLimitNavInvariantTest is Deployers {
    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;
    MockAggregatorV3 internal feed;

    PoolKey internal blKey;
    PoolId internal blId;

    address internal refHolder = makeAddr("refHolder");
    address[2] internal foreign;

    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant COOLDOWN = 3_600;
    // refHolder deposit per token per tranche — DOMINANT liquidity so foreign churn + tiny self-swaps
    // move the pool spot only negligibly (token0+token1 stays a faithful NAV measure ~1:1).
    uint256 internal constant SEED = 500_000e18;

    uint256 internal refIn; // value the refHolder deposited (token0+token1), both tranches
    uint256 internal ghostForeignIn;
    uint256 internal ghostForeignOut;

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));
        feed = new MockAggregatorV3(8);
        feed.set(1e8, T0);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0xB11D) << 14));
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), IAnchorStaking(address(0)), address(shareImpl), address(this), address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);

        blKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        // v3.3 permissionless creation: team-curation lever must be set before pool creation.
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        blId = vault.createBaseLimitPool(blKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME-BL", "mBL");

        _fund(refHolder, 2_100_000e18);
        foreign[0] = makeAddr("foreignA");
        foreign[1] = makeAddr("foreignB");
        _fund(foreign[0], 300_000e18);
        _fund(foreign[1], 300_000e18);

        // refHolder seeds BOTH tranches — dominant, price-pinning liquidity.
        refIn += _depositMeasured(refHolder, 0, SEED, SEED);
        refIn += _depositMeasured(refHolder, 1, SEED, SEED);
        vm.warp(block.timestamp + COOLDOWN + FeraConstants.JIT_PENALTY_WINDOW_MEME + 1);
        _refresh();
    }

    function _fund(address who, uint256 amt) internal {
        MockERC20(Currency.unwrap(currency0)).transfer(who, amt);
        MockERC20(Currency.unwrap(currency1)).transfer(who, amt);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _bal(address who) internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(Currency.unwrap(currency0)).balanceOf(who);
        b1 = IERC20(Currency.unwrap(currency1)).balanceOf(who);
    }

    /// @dev A tiny net-zero swap pair to keep the TWAP head fresh (REC-9 fail-closed avoidance).
    function _refresh() internal {
        try this.extSwap(true, -1e14) {} catch {}
        try this.extSwap(false, -1e14) {} catch {}
    }

    function extSwap(bool zeroForOne, int256 amt) external {
        swap(blKey, zeroForOne, amt, "");
    }

    function _depositMeasured(address who, uint8 t, uint256 a0, uint256 a1) internal returns (uint256 valueIn) {
        (uint256 b0, uint256 b1) = _bal(who);
        vm.prank(who);
        vault.deposit(blId, t, a0, a1, 0);
        (uint256 m0, uint256 m1) = _bal(who);
        valueIn = (b0 - m0) + (b1 - m1);
    }

    function _withdrawAllMeasured(address who, uint8 t) internal returns (uint256 valueOut) {
        IERC20 share = IERC20(vault.shareToken(blId, t));
        uint256 bal = share.balanceOf(who);
        if (bal == 0) return 0;
        (uint256 b0, uint256 b1) = _bal(who);
        // Universal async redemption (guarded): request → delay → claim (in-kind — no TWAP dependency).
        vm.prank(who);
        share.approve(address(vault), bal);
        vm.prank(who);
        try vault.requestWithdraw(blId, t, bal, 0, 0) returns (uint256 rid) {
            vm.warp(block.timestamp + QW.DELAY);
            try vault.claimWithdraw(rid) {
                (uint256 m0, uint256 m1) = _bal(who);
                valueOut = (m0 - b0) + (m1 - b1);
            } catch {}
        } catch {}
    }

    // ── one guarded action decoded from a seed ─────────────────────────────────────────────────
    function _step(uint256 seed) internal {
        uint256 op = seed % 10;
        address actor = foreign[(seed >> 8) & 1];
        uint8 t = uint8((seed >> 16) & 1);
        uint256 amt = bound(seed >> 24, 1e18, 200e18); // « the dominant refHolder base ⇒ spot stays ~1:1

        if (op == 0 || op == 1) {
            // foreign deposit (may fail-closed on a stale TWAP after long warps — guarded)
            (uint256 b0, uint256 b1) = _bal(actor);
            vm.prank(actor);
            try vault.deposit(blId, t, amt, amt, 0) {
                (uint256 m0, uint256 m1) = _bal(actor);
                ghostForeignIn += (b0 - m0) + (b1 - m1);
            } catch {}
        } else if (op == 2) {
            // foreign FULL in-kind exit (after cooldown)
            vm.warp(block.timestamp + COOLDOWN + 1);
            _refresh();
            ghostForeignOut += _withdrawAllMeasured(actor, t);
        } else if (op == 3) {
            // foreign FULL single-coin exit (self-swaps the unwanted leg — bounded, output ≤ pro-rata).
            // Universal async redemption: request → delay → claim; the bounded self-swap runs at CLAIM,
            // so the TWAP is refreshed AFTER the 24h warp (which would otherwise leave it stale).
            vm.warp(block.timestamp + COOLDOWN + 1);
            _refresh();
            IERC20 share = IERC20(vault.shareToken(blId, t));
            uint256 bal = share.balanceOf(actor);
            if (bal != 0) {
                address tok = (seed & 1) == 0 ? Currency.unwrap(currency0) : Currency.unwrap(currency1);
                (uint256 b0, uint256 b1) = _bal(actor);
                vm.prank(actor);
                share.approve(address(vault), bal);
                vm.prank(actor);
                try vault.requestWithdrawSingle(blId, t, bal, tok, 0) returns (uint256 rid) {
                    vm.warp(block.timestamp + QW.DELAY);
                    _refresh();
                    try vault.claimWithdraw(rid) {
                        (uint256 m0, uint256 m1) = _bal(actor);
                        ghostForeignOut += (m0 - b0) + (m1 - b1);
                    } catch {}
                } catch {}
            }
        } else if (op == 4) {
            try vault.skimIdle(blId, t) {} catch {}
        } else if (op == 5) {
            vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
            _refresh();
            try vault.rebalanceLimit(blId, t) {} catch {}
        } else if (op == 6) {
            // TINY keeper self-swap (kept small so impact is negligible ⇒ value stays internal, pool
            // stays ~1:1). Interval-gated (guarded).
            vm.warp(block.timestamp + FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC + 1);
            _refresh();
            (uint256 r0, uint256 r1) = vault.idleReserves(blId, t);
            bool z = (seed & 1) == 0;
            uint256 a = (z ? r0 : r1) / 200;
            if (a != 0) {
                try vault.selfSwap(blId, t, z, a) {} catch {}
            }
        } else if (op == 7) {
            // rebalanceBase attempt (gate-rejected near spot — exercises the gate stack)
            vault.pokeOutOfRange(blId, t);
            try vault.rebalanceBase(blId, t, (seed & 1) == 0) {} catch {}
        } else if (op == 8) {
            vault.pokeOutOfRange(blId, t);
        } else {
            vm.warp(block.timestamp + bound(seed, 1, 1_200));
            _refresh();
        }
    }

    /// @notice NO-OVER-EXTRACTION + NON-DILUTION across the base+limit+idle sequences. Swap-free at the
    ///         pool level (vault is the sole LP; self-swaps are tiny + internal), so NAV is conserved:
    ///         no interleaving of foreign churn (deposit/withdraw/withdrawSingle) and keeper rebalancing
    ///         (skimIdle/rebalanceLimit/selfSwap/rebalanceBase) lets ANY actor extract more than they put in.
    function testFuzz_baseLimit_navConserved_stateful(uint256[12] calldata seeds) public {
        for (uint256 i; i < seeds.length; ++i) {
            _step(seeds[i]);
        }

        // Everyone exits (withdrawals are never gated — INV-11).
        vm.warp(block.timestamp + COOLDOWN + 1);
        _refresh();
        for (uint256 k; k < 2; ++k) {
            ghostForeignOut += _withdrawAllMeasured(foreign[0], uint8(k));
            ghostForeignOut += _withdrawAllMeasured(foreign[1], uint8(k));
        }
        uint256 refOut;
        refOut += _withdrawAllMeasured(refHolder, 0);
        refOut += _withdrawAllMeasured(refHolder, 1);

        // (A) NO OVER-EXTRACTION (the exploit direction): foreigners who churn through the base+limit
        //     paths never withdraw more value than they deposited — a withdrawSingle self-swap only LOSES
        //     value (slippage/fee), and that loss stays inside the vault with the remaining holders. The
        //     only slack is dust (last-wei rounding + the fee-floor income brief holders barely touch).
        assertLe(ghostForeignOut, ghostForeignIn + 5e18, "base+limit: foreign actor extracted value from nothing");

        // (B) GLOBAL CONSERVATION (INV-16): total value withdrawn ≤ total value deposited. No sequence of
        //     deposit/withdraw/withdrawSingle/skimIdle/rebalanceLimit/selfSwap/rebalanceBase mints value
        //     from nothing. (The refHolder MAY end up ahead of its own deposit — it legitimately captures
        //     the exiting churners' self-swap slippage as the dominant remaining holder — but the TOTAL
        //     out can never exceed the TOTAL in beyond dust + the tiny external TWAP-refresh fee income.)
        assertLe(refOut + ghostForeignOut, refIn + ghostForeignIn + 5e18, "base+limit: value minted from nothing");

        // (C) NON-DILUTION: the refHolder recovers ~its full deposit. Permitted loss: rounding, the
        //     per-first-deposit MINIMUM_LIQUIDITY dust (2 tranches × 1000 wei), and bounded keeper
        //     self-swap slippage — a 10bp floor is comfortable given the tiny self-swaps.
        assertGe(refOut, (refIn * 9_995) / 10_000, "base+limit: refHolder was diluted");
    }
}
