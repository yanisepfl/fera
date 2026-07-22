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
import {DecimalsRevertingAggregatorV3} from "../utils/Mocks.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice PoC for the v3.5.1 fix (audit finding, medium): `VaultMath.tryReadOracle` /
///         `VaultOps._tryReadOracle` call `IAggregatorV3(feed).decimals()` OUTSIDE the scope of the
///         `try IAggregatorV3(feed).latestRoundData() ... catch { return (0,false); }` block that
///         guards the function. Solidity's try/catch only guards the single call named after `try` —
///         a feed whose `decimals()` reverts (upgraded/paused proxy, malformed/hostile
///         implementation) AFTER passing `FeraHook.setOracleFeed`'s one-time registration snapshot
///         used to propagate that revert straight out of `tryReadOracle`/`_tryReadOracle`, breaking
///         their documented "never reverts" contract — exactly the failure mode the adjacent v3.5 FIX
///         comment (the >18-decimals ternary) claims to have eliminated, and unlike FeraHook's
///         `_oraclePriceX96`, which never calls `.decimals()` live at all (cached at registration).
///
///         Fix: `decimals()` now sits behind its own try/catch in both copies, degrading to
///         `(0, false)` exactly like every other feed failure mode.
contract OracleDecimalsRevertPoCTest is Deployers {
    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;
    DecimalsRevertingAggregatorV3 internal feed;

    PoolKey internal rwaKey;
    PoolId internal rwaId;

    uint256 internal constant T0 = 10_000_000;

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));

        // decimals() succeeds by default (8, like a real Chainlink feed) so the mock can pass through
        // FeraHook.setOracleFeed's one-time registration snapshot exactly like a genuine feed would —
        // the whole point of this PoC is a feed that degrades AFTER registration, not one that was
        // already broken at createBaseLimitPool time (that latter case is FeraHook's problem to
        // surface, and it already does, deliberately, per its own NatSpec).
        feed = new DecimalsRevertingAggregatorV3();
        feed.set(1e8, block.timestamp);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x4343) << 14));
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

        rwaKey = PoolKey({currency0: currency0, currency1: currency1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 10, hooks: IHooks(hookAddr)});

        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        vault.approveRwaFeed(address(feed), "decimals-toggle test feed");
        rwaId = vault.createBaseLimitPool(rwaKey, FeraTypes.Regime.RWA, address(feed), SQRT_PRICE_1_1, true, "RWA-BL", "rBL");
        vault.setKeeperActive(rwaId, true);

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vault.deposit(rwaId, 1, 1_000e18, 1_000e18, 0);
    }

    function _refreshTwap() internal {
        swap(rwaKey, true, -1e15, "");
        swap(rwaKey, false, -1e15, "");
    }

    /// `VaultMath.tryReadOracle` consumer: `VaultRwa.rebalanceRwaOracle` (VaultRwa.sol:51) already
    /// handles an unavailable oracle cleanly — `if (!ok) revert OracleUnavailable();`. A
    /// decimals()-reverting feed must degrade INTO that same clean path, not bubble the feed's raw
    /// revert reason.
    function test_decimalsReverts_tryReadOracle_degradesToCleanOracleUnavailable() public {
        vault.setMarketOpen(rwaId, true);
        vm.warp(block.timestamp + 200);
        _refreshTwap();
        feed.set(int256(134_980_000), block.timestamp); // fresh, healthy answer — only decimals() is broken
        feed.setDecimalsReverting(true);

        // POST-FIX: degrades to (0,false) inside tryReadOracle, so the caller's OWN ok-check produces
        // the documented, clean revert. PRE-FIX this reverted with the feed's raw "decimals down"
        // reason instead (a bare STRING revert, not this selector) — `vm.expectRevert(selector)` would
        // NOT have matched it, so this assertion fails before the fix and passes after.
        vm.expectRevert(IFeraVault.OracleUnavailable.selector);
        vault.rebalanceRwaOracle(rwaId, 1);
    }

    /// `VaultOps._tryReadOracle` consumer: `_inventorySkewBps` (called from `cbRebalanceLimit`, via
    /// the keeper-only `rebalanceLimit`) has NO enclosing try/catch at all — the whole keeper action
    /// used to revert outright on a decimals()-reverting feed (a functional DoS), instead of gracefully
    /// falling back to inventory-only skew as the `ok=false` path is designed to allow.
    function test_decimalsReverts_tryReadOracle_doesNotDosRebalanceLimit() public {
        vm.warp(block.timestamp + 200);
        _refreshTwap();
        // `_inventorySkewBps` short-circuits to a flat floor (skipping the oracle read entirely) when
        // the tranche's reserve is empty — skimIdle first so there is real reserve to weight, exactly
        // like the equivalent MEME rebalanceLimit PoC (BaseLimitStrategy.t.sol) does.
        vault.skimIdle(rwaId, 1);
        feed.setDecimalsReverting(true);

        // PRE-FIX: reverts with the feed's raw "decimals down" reason — an unrelated keeper action
        // completely DoS'd by a decimals()-reverting feed. POST-FIX: succeeds (inventory-only skew).
        vault.rebalanceLimit(rwaId, 1);
    }
}
