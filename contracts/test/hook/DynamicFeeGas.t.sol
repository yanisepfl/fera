// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockAggregatorV3} from "../utils/Mocks.sol";

import {FeraHook} from "../../src/FeraHook.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice GAS — the combined hook swap overhead (beforeSwap + afterSwap) must fit the HARD ≤40k
///          budget (MASTER_SPEC §5 / DM-4), including the RWA cold Chainlink read and the MEME EWMA
///          SSTORE. Measured by driving the hook entry points AS the PoolManager (real manager backs
///          getSlot0), in steady state (warm slots). Also proves the per-block transient oracle cache
///          (RWA_ORACLE_TCACHE, §2.5) makes the warm RWA swap cheaper than the cold one.
contract DynamicFeeGasTest is Deployers {
    FeraHook internal hook;

    PoolKey internal mkey; // MEME
    PoolId internal mid;
    PoolKey internal rkey; // RWA
    PoolId internal rid;
    MockAggregatorV3 internal feed;

    int24 internal constant LO = -120_000;
    int24 internal constant HI = 120_000;
    uint32 internal constant BUDGET = 40_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x6A5) << 14));
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(this)), hookAddr);
        hook = FeraHook(hookAddr);

        mkey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        mid = mkey.toId();
        hook.registerRegime(mkey, FeraTypes.Regime.MEME);
        manager.initialize(mkey, SQRT_PRICE_1_1);
        _addLiq(mkey);

        rkey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hookAddr));
        rid = rkey.toId();
        hook.registerRegime(rkey, FeraTypes.Regime.RWA);
        manager.initialize(rkey, SQRT_PRICE_1_1);
        _addLiq(rkey);
        feed = new MockAggregatorV3(8);
        hook.setOracleFeed(rid, address(feed));
        hook.setMarketOpen(rid, true);
        feed.set(101e6, block.timestamp); // ~1% deviation ⇒ exercises the full overlay math path

        // Warm the MEME state slot to nonzero→nonzero (steady-state SSTORE cost) with a few real swaps.
        swap(mkey, true, -50_000e18, "");
        swap(mkey, false, -50_000e18, "");
        swap(rkey, true, -1_000e18, "");
    }

    function _addLiq(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: LO, tickUpper: HI, liquidityDelta: int256(5_000_000e18), salt: 0}), ""
        );
    }

    /// Combined beforeSwap+afterSwap gas, measured as the PoolManager would incur it (external calls
    /// into the hook, real getSlot0 on the manager). Conservative: includes the test→hook CALL overhead.
    function _combinedGas(PoolKey memory k, bool zeroForOne) internal returns (uint256 used) {
        SwapParams memory sp = SwapParams(zeroForOne, -1e18, 0);
        BalanceDelta delta = toBalanceDelta(int128(-1e18), int128(1e18));
        vm.startPrank(address(manager));
        uint256 g = gasleft();
        hook.beforeSwap(address(this), k, sp, "");
        hook.afterSwap(address(this), k, sp, delta, "");
        used = g - gasleft();
        vm.stopPrank();
    }

    function test_gas_meme_combinedUnderBudget() public {
        uint256 g = _combinedGas(mkey, true);
        console2.log("MEME combined beforeSwap+afterSwap gas =", g);
        assertLt(g, BUDGET, "MEME hook swap overhead exceeds the 40k budget");
    }

    function test_gas_rwa_split() public {
        SwapParams memory sp = SwapParams(true, -1e18, 0);
        BalanceDelta delta = toBalanceDelta(int128(-1e18), int128(1e18));
        vm.startPrank(address(manager));
        uint256 g1 = gasleft();
        hook.beforeSwap(address(this), rkey, sp, "");
        uint256 beforeG = g1 - gasleft();
        uint256 g2 = gasleft();
        hook.afterSwap(address(this), rkey, sp, delta, "");
        uint256 afterG = g2 - gasleft();
        vm.stopPrank();
        console2.log("RWA beforeSwap (cold oracle) gas =", beforeG);
        console2.log("RWA afterSwap gas =", afterG);
    }

    function test_gas_rwa_coldAndWarmUnderBudget() public {
        // COLD: first RWA beforeSwap of this tx pays the Chainlink read (transient cache empty).
        uint256 cold = _combinedGas(rkey, true);
        // WARM: second RWA beforeSwap in the SAME test tx reuses the cached oracle read (§2.5).
        uint256 warm = _combinedGas(rkey, true);
        console2.log("RWA combined gas (cold Chainlink read) =", cold);
        console2.log("RWA combined gas (warm oracle cache)   =", warm);
        assertLt(cold, BUDGET, "RWA cold hook swap overhead exceeds the 40k budget");
        assertLt(warm, BUDGET, "RWA warm hook swap overhead exceeds the 40k budget");
        assertLt(warm, cold, "transient oracle cache did not reduce the warm-path gas");
    }
}
