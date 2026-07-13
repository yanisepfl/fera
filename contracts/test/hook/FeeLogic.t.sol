// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeLogic} from "../../src/libraries/FeeLogic.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @notice §5 / INV-2 — the dynamic-fee curve NEVER reverts and always returns a bounded LP fee;
///         extreme inputs and oracle failure clamp to the regime ceiling / blind fee (never a swap
///         block). Plus the frozen worked examples from MECHANISM_SPEC §1.8 / §2.6.
contract FeeLogicTest is Test {
    /// MEME: any EWMA state input clamps into [floor, hardMax] and never reverts.
    function testFuzz_meme_clampsAndNeverReverts(uint256 volX, int256 flowX, bool isSell) public pure {
        flowX = bound(flowX, type(int64).min, type(int64).max);
        FeeLogic.FeeInputs memory fi;
        fi.regime = FeraTypes.Regime.MEME;
        fi.isSell = isSell;
        fi.volEwmaX = volX;
        fi.flowEwmaX = flowX;
        uint24 fee = FeeLogic.quoteLpFee(fi);
        assertGe(fee, FeraConstants.MEME_FEE_FLOOR_PIPS, "below MEME floor");
        assertLe(fee, FeraConstants.MEME_FEE_HARD_MAX_PIPS, "above MEME hard max");
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE, "above v4 max");
    }

    /// MEME buy side is capped at the symmetric ceiling (the sell adder never applies to buys).
    function testFuzz_meme_buySideCappedAtCeil(uint256 volX, int256 flowX) public pure {
        flowX = bound(flowX, type(int64).min, type(int64).max);
        FeeLogic.FeeInputs memory fi;
        fi.regime = FeraTypes.Regime.MEME;
        fi.isSell = false;
        fi.volEwmaX = volX;
        fi.flowEwmaX = flowX;
        assertLe(FeeLogic.quoteLpFee(fi), FeraConstants.MEME_FEE_CEIL_PIPS, "buy above MEME ceil");
    }

    /// MECHANISM_SPEC §1.8 "Quiet": σ=3 ⇒ feeBase = floor (dead-band, SIGMA0=4). volX = σ²·2^16.
    function test_meme_quietIsFloor() public pure {
        FeeLogic.FeeInputs memory fi;
        fi.regime = FeraTypes.Regime.MEME;
        fi.volEwmaX = uint256(3 * 3) << 16; // σ ≈ 3
        assertEq(FeeLogic.quoteLpFee(fi), FeraConstants.MEME_FEE_FLOOR_PIPS, "quiet != floor");
    }

    /// MECHANISM_SPEC §1.8 "Pump": σ=40 ⇒ feeBase = 3400 + 200·36 = 10600; buy pays exactly feeBase.
    function test_meme_pumpBaseIs10600() public pure {
        FeeLogic.FeeInputs memory fi;
        fi.regime = FeraTypes.Regime.MEME;
        fi.volEwmaX = uint256(40 * 40) << 16; // σ ≈ 40
        fi.isSell = false;
        assertEq(FeeLogic.quoteLpFee(fi), 10_600, "pump base != 10600");
    }

    /// MECHANISM_SPEC §1.6: a fully one-sided DOWN flow adds up to SELL_K on the sell side; a buy
    /// (dip-arb) pays only feeBase. Sell fee strictly exceeds the buy fee under negative flow.
    function test_meme_sellAdderExceedsBuy() public pure {
        FeeLogic.FeeInputs memory buy;
        buy.regime = FeraTypes.Regime.MEME;
        buy.volEwmaX = uint256(55 * 55) << 16; // σ ≈ 55
        buy.flowEwmaX = -int256(48) << 16; // F = −48 (dump)
        buy.isSell = false;
        uint24 buyFee = FeeLogic.quoteLpFee(buy);

        FeeLogic.FeeInputs memory sell = buy;
        sell.isSell = true;
        uint24 sellFee = FeeLogic.quoteLpFee(sell);

        assertEq(buyFee, 13_600, "dump buy base != 13600");
        assertGt(sellFee, buyFee, "sell adder did not raise the fee");
        assertLe(sellFee, FeraConstants.MEME_FEE_HARD_MAX_PIPS, "sell above hard max");
        // adder = SELL_K·|imb|, imb ≈ 0.85 ⇒ sell ≈ 13600 + ~17k ≈ 30–31k.
        assertApproxEqAbs(uint256(sellFee), 30_743, 500, "sell fee off spec 1.8 dump row");
    }

    /// RWA oracle failure (oraclePrice == 0) quotes the flat blind-pool fee and NEVER reverts (§5).
    function test_rwa_oracleFailUsesBlindFee() public pure {
        FeeLogic.FeeInputs memory fi;
        fi.regime = FeraTypes.Regime.RWA;
        fi.marketOpen = true;
        fi.poolPriceX96 = 123;
        fi.oraclePriceX96 = 0; // unavailable
        assertEq(FeeLogic.quoteLpFee(fi), FeraConstants.RWA_ORACLE_FAIL_FEE_PIPS, "oracle-fail != blind fee");
    }

    /// MECHANISM_SPEC §2.6 "Open/quiet": dev 0.05% (5 bp) ⇒ 200 + 20·5 = 300 pips.
    function test_rwa_openQuietIs300() public pure {
        FeeLogic.FeeInputs memory fi;
        fi.regime = FeraTypes.Regime.RWA;
        fi.marketOpen = true;
        fi.oraclePriceX96 = 1e18;
        fi.poolPriceX96 = 1e18 + (1e18 * 5) / 10_000; // +0.05%
        assertEq(FeeLogic.quoteLpFee(fi), 300, "open/quiet != 300 pips");
    }

    /// MECHANISM_SPEC §2.6 "Closed/drifting": dev 2% ⇒ 3000 + 20·200 = 7000 pips.
    function test_rwa_closedDriftIs7000() public pure {
        FeeLogic.FeeInputs memory fi;
        fi.regime = FeraTypes.Regime.RWA;
        fi.marketOpen = false;
        fi.oraclePriceX96 = 1e18;
        fi.poolPriceX96 = 1e18 + (1e18 * 200) / 10_000; // +2%
        assertEq(FeeLogic.quoteLpFee(fi), 7_000, "closed/drift != 7000 pips");
    }

    /// RWA with a huge deviation clamps to the ceiling (never reverts, never blocks the swap).
    function testFuzz_rwa_deviationClamps(uint256 poolP, uint256 oracleP, bool marketOpen) public pure {
        poolP = bound(poolP, 1, type(uint128).max);
        oracleP = bound(oracleP, 1, type(uint128).max);
        FeeLogic.FeeInputs memory fi;
        fi.regime = FeraTypes.Regime.RWA;
        fi.marketOpen = marketOpen;
        fi.poolPriceX96 = poolP;
        fi.oraclePriceX96 = oracleP;
        uint24 fee = FeeLogic.quoteLpFee(fi);
        assertGe(fee, FeraConstants.RWA_FEE_INHOURS_PIPS, "below RWA floor");
        assertLe(fee, FeraConstants.RWA_FEE_CEIL_PIPS, "above RWA ceil");
    }

    /// The dynamic-fee sentinel mirrors v4-core exactly (drift guard, FeraConstants).
    function test_dynamicFeeFlag_matchesV4() public pure {
        assertEq(FeraConstants.DYNAMIC_FEE_FLAG, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(uint256(FeraConstants.MAX_LP_FEE_PIPS), uint256(LPFeeLibrary.MAX_LP_FEE));
    }
}
