// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FeraVault} from "../../src/FeraVault.sol";
import {FeraShare} from "../../src/shares/FeraShare.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice R-17 — the Bunni Sept-2025 exploit class, replayed against FERA's share accounting.
///         Bunni ($8.4M): 44 micro-withdrawals exploited withdraw-rounding in the idle-balance
///         accounting so each withdrawal ratcheted the attacker's claim UP. The mandatory PoC here
///         drives many micro-withdrawals against the band-ladder vault and asserts the two
///         properties that kill the class:
///          (1) the withdrawer can NEVER extract more than pro-rata (rounding is ALWAYS against
///              the withdrawer — attacker round-trip is a strict loss with zero fees), and
///          (2) remaining holders' claims never grow beyond collected fees (zero here) + the
///              attacker's forfeited rounding dust — no value is created by iteration count.
contract RatchetPoCTest is Deployers {
    FeraVault internal vault;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;

    PoolKey internal poolKey;
    PoolId internal id;

    address internal honest = makeAddr("honest");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant COOLDOWN = 3_600;

    function setUp() public {
        vm.warp(T0);
        deployFreshManager();
        (currency0, currency1) = deployAndMint2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x9999) << 14));
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), address(shareImpl), address(this), address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        id = vault.createPool(poolKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, "FERA-LP", "fLP");

        _fund(honest, 200e18);
        _fund(attacker, 20e18);
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

    /// The Bunni replay: N micro-withdrawals must never ratchet the attacker's take above
    /// pro-rata, and must never inflate the honest holder's claim beyond dust.
    function test_R17_microWithdrawRatchet_neverProfits() public {
        // Honest majority deposits; attacker joins.
        (uint256 h0Before, uint256 h1Before) = _bal(honest);
        vm.prank(honest);
        uint256 hShares = vault.deposit(id, 0, 100e18, 100e18, 0);
        (uint256 h0Mid, uint256 h1Mid) = _bal(honest);
        uint256 hIn0 = h0Before - h0Mid;
        uint256 hIn1 = h1Before - h1Mid;

        (uint256 a0Before, uint256 a1Before) = _bal(attacker);
        vm.prank(attacker);
        uint256 aShares = vault.deposit(id, 0, 10e18, 10e18, 0);
        (uint256 a0Mid, uint256 a1Mid) = _bal(attacker);
        uint256 aIn0 = a0Before - a0Mid;
        uint256 aIn1 = a1Before - a1Mid;

        vm.warp(block.timestamp + COOLDOWN); // both cooldowns lapse

        // 44 micro-withdrawals (the Bunni count) + the final remainder.
        uint256 slice = aShares / 45;
        vm.startPrank(attacker);
        for (uint256 i; i < 44; ++i) {
            vault.withdraw(id, 0, slice, 0, 0);
        }
        vault.withdraw(id, 0, aShares - 44 * slice, 0, 0);
        vm.stopPrank();

        // (1) Rounding is ALWAYS against the withdrawer: strict no-profit round trip.
        (uint256 a0After, uint256 a1After) = _bal(attacker);
        uint256 aOut0 = a0After - a0Mid;
        uint256 aOut1 = a1After - a1Mid;
        assertLe(aOut0, aIn0, "RATCHET: attacker extracted token0 above pro-rata");
        assertLe(aOut1, aIn1, "RATCHET: attacker extracted token1 above pro-rata");
        // ...and the dust lost is bounded (sanity: micro-splitting costs, never pays).
        assertApproxEqRel(aOut0, aIn0, 0.001e18, "attacker lost >10bp to rounding (too lossy)");

        // (2) Remaining holders' claim never grows beyond collected fees (ZERO here) + dust the
        //     attacker forfeited. The honest exit proves it: out ≤ in + attacker's dust; out ≈ in.
        vm.startPrank(honest);
        vault.withdraw(id, 0, hShares, 0, 0);
        vm.stopPrank();
        (uint256 h0After, uint256 h1After) = _bal(honest);
        uint256 hOut0 = h0After - h0Mid;
        uint256 hOut1 = h1After - h1Mid;

        uint256 aDust0 = aIn0 - aOut0;
        uint256 aDust1 = aIn1 - aOut1;
        assertLe(hOut0, hIn0 + aDust0, "honest claim grew beyond fees(0) + forfeited dust");
        assertLe(hOut1, hIn1 + aDust1, "honest claim grew beyond fees(0) + forfeited dust");
        assertApproxEqRel(hOut0, hIn0, 0.001e18, "honest principal eroded");
        assertApproxEqRel(hOut1, hIn1, 0.001e18, "honest principal eroded");

        // Global conservation: nobody minted value out of the pool.
        assertLe(hOut0 + aOut0, hIn0 + aIn0, "token0 created from nothing");
        assertLe(hOut1 + aOut1, hIn1 + aIn1, "token1 created from nothing");
    }

    /// Fuzzed slice sizes: no micro-withdrawal pattern is profitable.
    function testFuzz_R17_anySliceCount_neverProfits(uint256 nSlices) public {
        nSlices = bound(nSlices, 2, 60);

        vm.prank(honest);
        vault.deposit(id, 0, 100e18, 100e18, 0);

        (uint256 a0Before, uint256 a1Before) = _bal(attacker);
        vm.prank(attacker);
        uint256 aShares = vault.deposit(id, 0, 10e18, 10e18, 0);
        (uint256 a0Mid, uint256 a1Mid) = _bal(attacker);

        vm.warp(block.timestamp + COOLDOWN);

        uint256 slice = aShares / nSlices;
        vm.startPrank(attacker);
        for (uint256 i; i + 1 < nSlices; ++i) {
            vault.withdraw(id, 0, slice, 0, 0);
        }
        vault.withdraw(id, 0, aShares - (nSlices - 1) * slice, 0, 0);
        vm.stopPrank();

        (uint256 a0After, uint256 a1After) = _bal(attacker);
        assertLe(a0After - a0Mid, a0Before - a0Mid, "profitable ratchet found (token0)");
        assertLe(a1After - a1Mid, a1Before - a1Mid, "profitable ratchet found (token1)");
    }
}
