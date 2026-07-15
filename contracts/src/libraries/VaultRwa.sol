// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IFeraVault} from "../interfaces/IFeraVault.sol";
import {IRevenueDistributor} from "../interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../interfaces/IAnchorStaking.sol";
import {FeraTypes} from "./FeraTypes.sol";
import {FeraConstants} from "./FeraConstants.sol";
import {VaultOps} from "./VaultOps.sol";
import {VaultMath} from "./VaultMath.sol";
import {VaultFees} from "./VaultFees.sol";
import {TierConfig, TrancheState, PoolInfo} from "./VaultTypes.sol";

/// @title VaultRwa
/// @notice EIP-170 SIZE-SPLIT of FeraVault (companion to VaultOps/VaultMath/VaultFees). Holds the two
///         RWA regime-appropriate defense entrypoints (`rebalanceRwaOracle`, `defendRwaOffHours`,
///         §5.1) as PUBLIC library functions, deployed as SEPARATE bytecode and delegatecalled from
///         FeraVault. Behavior — every gate, the swap-free value-conservation bound, the dedicated
///         base-recenter clock, and the emitted `StrategyAction` — is byte-identical to the pre-split
///         inline code. The `nonReentrant`/`knownTranche` modifiers remain on the vault's thin
///         wrappers (they gate on the vault's own guard + pool state). The per-(pool,tranche) clocks
///         are passed as the inner `mapping(uint256 => uint64)` (i.e. `lastX[id]`), indexed by `c.t`.
library VaultRwa {
    using StateLibrary for IPoolManager;

    // Callback action tags — MUST match FeraVault's internal encoding.
    uint8 internal constant CB_RWA_ORACLE_RECENTER = 10;
    uint8 internal constant CB_RWA_DEFEND = 11;

    /// @notice RWA IN-HOURS oracle-anchored base recenter (§5.1). Re-anchors the base band TOWARD the
    ///         Chainlink oracle on a TWAP-confirmed, hysteresis-clearing in-hours drift. Swap-free.
    function rebalanceRwaOracle(
        TrancheState storage tr,
        PoolInfo storage p,
        TierConfig storage cfg,
        VaultOps.Ctx memory c,
        IRevenueDistributor rd,
        IAnchorStaking anchor,
        mapping(uint256 => uint64) storage baseRecenterClock,
        mapping(uint256 => uint64) storage rebalanceClock
    ) public {
        if (!cfg.set) revert IFeraVault.NotBaseLimitPool();
        if (p.regime != FeraTypes.Regime.RWA) revert IFeraVault.NotRwaPool();
        // In-hours only, and NOT during a flagged event window.
        if (!_isMarketOpen(p) || p.eventWindow) revert IFeraVault.MarketClosed();
        // The oracle is the anchor — it MUST be readable (fresh, positive). No blind recenter.
        (uint256 oracle, bool ok) = VaultMath.tryReadOracle(p);
        if (!ok) revert IFeraVault.OracleUnavailable();
        // Dedicated slow base-recenter clock (RWA cadence, 4h) — no churn.
        _requireIntervalSince(baseRecenterClock[c.t], _baseRecenterMinInterval(p));
        // Hysteresis: only act on a MEANINGFUL pool-vs-oracle drift (else it is pure churn).
        (uint160 sqrtSpot,,,) = c.pm.getSlot0(c.id);
        uint256 spot = VaultMath.priceFromSqrt(sqrtSpot);
        if (VaultMath.absDeviationBps(spot, oracle) < FeraConstants.RWA_ORACLE_RECENTER_HYSTERESIS_BPS) {
            revert IFeraVault.OracleDeviationTooSmall();
        }
        // TWAP sanity: the drift must be GENUINE (sustained), not a spot spike.
        if (VaultMath.twapDeviationBps(c, FeraConstants.REBALANCE_TWAP_WINDOW_SEC) > FeraConstants.REBALANCE_TWAP_SANITY_BPS)
        {
            revert IFeraVault.TwapOutOfBand();
        }

        VaultFees.checkpoint(tr, p, c, rd, anchor);
        (uint256 vBefore,,) = VaultMath.trancheValue(tr, c);
        int24 oracleTick = VaultMath.oracleTick(oracle);
        c.pm.unlock(abi.encode(CB_RWA_ORACLE_RECENTER, c.id, c.t, abi.encode(oracleTick)));
        (uint256 vAfter,, int24 tick) = VaultMath.trancheValue(tr, c);
        // Swap-free ⇒ value conserved to dust; a Gate-5-style bound catches any pathology.
        if (vAfter * FeraConstants.BPS < vBefore * (FeraConstants.BPS - FeraConstants.MAX_REBALANCE_SLIPPAGE_BPS)) {
            revert IFeraVault.RebalanceSlippage();
        }
        baseRecenterClock[c.t] = uint64(block.timestamp);
        rebalanceClock[c.t] = uint64(block.timestamp);
        emit IFeraVault.StrategyAction(
            PoolId.unwrap(c.id), uint8(FeraTypes.StrategyKind.Recenter), tick, oracleTick, oracle, bytes32("rwa-oracle")
        );
    }

    /// @notice RWA OFF-HOURS / EVENT-WINDOW defensive posture (§5.1): WIDEN the base band + PARTIAL-
    ///         WITHDRAW a fraction into idle reserve. Eligible when the market is closed OR an event
    ///         window is flagged. Swap-free / value-conserving.
    function defendRwaOffHours(
        TrancheState storage tr,
        PoolInfo storage p,
        TierConfig storage cfg,
        VaultOps.Ctx memory c,
        IRevenueDistributor rd,
        IAnchorStaking anchor,
        mapping(uint256 => uint64) storage baseRecenterClock,
        mapping(uint256 => uint64) storage rebalanceClock
    ) public {
        if (!cfg.set) revert IFeraVault.NotBaseLimitPool();
        if (p.regime != FeraTypes.Regime.RWA) revert IFeraVault.NotRwaPool();
        // Eligible ONLY when the market is closed OR an event window is flagged.
        if (_isMarketOpen(p) && !p.eventWindow) revert IFeraVault.MarketOpen();
        _requireIntervalSince(baseRecenterClock[c.t], _baseRecenterMinInterval(p));

        VaultFees.checkpoint(tr, p, c, rd, anchor);
        (uint256 vBefore,,) = VaultMath.trancheValue(tr, c);
        c.pm.unlock(abi.encode(CB_RWA_DEFEND, c.id, c.t, bytes("")));
        (uint256 vAfter,, int24 tick) = VaultMath.trancheValue(tr, c);
        // Swap-free ⇒ value conserved to dust (removing + re-adding liquidity only rounds against us).
        if (vAfter * FeraConstants.BPS < vBefore * (FeraConstants.BPS - FeraConstants.MAX_REBALANCE_SLIPPAGE_BPS)) {
            revert IFeraVault.RebalanceSlippage();
        }
        baseRecenterClock[c.t] = uint64(block.timestamp);
        rebalanceClock[c.t] = uint64(block.timestamp);
        emit IFeraVault.StrategyAction(
            PoolId.unwrap(c.id), uint8(FeraTypes.StrategyKind.Widen), tick, tick, 0, bytes32("rwa-offhours")
        );
    }

    // ── local ports of the vault's gate helpers ──────────────────────────────────────────────

    /// @dev Market-hours check (SEC-3 #7 / §10): holiday → keeper flag → weekly UTC schedule bitmap.
    function _isMarketOpen(PoolInfo storage p) internal view returns (bool) {
        if (p.holiday) return false;
        if (!p.marketOpen) return false;
        uint256 sched = p.scheduleBitmap;
        if (sched == 0) return true;
        // slither-disable-next-line weak-prng — hour-of-week calendar index (modulo), not randomness.
        uint256 hourOfWeek = (block.timestamp / 3_600) % 168;
        return (sched >> hourOfWeek) & 1 == 1;
    }

    /// @dev V3-HARDENING (§5.1): dedicated base-recenter min-interval — RWA reuses its 4h general clock.
    function _baseRecenterMinInterval(PoolInfo storage p) internal view returns (uint32) {
        return p.regime == FeraTypes.Regime.MEME
            ? FeraConstants.MEME_BASE_RECENTER_MIN_INTERVAL_SEC
            : FeraConstants.RWA_MIN_REBALANCE_INTERVAL_SEC;
    }

    function _requireIntervalSince(uint64 last, uint32 minInterval) internal view {
        if (last != 0 && block.timestamp - last < minInterval) revert IFeraVault.RebalanceTooSoon();
    }
}
