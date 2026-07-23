// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FeraTypes} from "./FeraTypes.sol";

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// Shared storage structs for the FeraVault managed-liquidity layer. Lifted OUT of the FeraVault
// contract (byte-for-byte identical field order + types) so the size-refactor libraries (VaultOps
// et al.) can receive `storage` references to the vault's own state via public-library delegatecall.
//
// STORAGE-LAYOUT NOTE: moving these declarations to file scope does NOT change the vault's storage
// layout — layout is fixed by the ORDER of the vault's state-variable declarations and by each
// struct's field order/types, all of which are preserved. Only the declaration SITE moved.
// ═══════════════════════════════════════════════════════════════════════════════════════════════

struct Band {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    bool isPrincipal; // BASE band: principal, never fee-funded
    uint16 weightBps; // weight at first mint (base band gets 100%)
    bool isLimit; // a near-spot inventory-skewed LIMIT band (principal-class surplus)
}

/// @notice Per-(pool,tranche) tier config (VAULT_STRATEGY_V3.md). Every tranche created via
///         `createBaseLimitPool` runs the base+limit+idle strategy — `set` is always true
///         post-creation; the flag is kept as a defensive belt-and-suspenders guard, not to
///         gate a second (non-existent) strategy path. `limitSkewBps` is INTENTIONALLY absent
///         (v3): the limit's skew is DERIVED from the tranche's actual token surplus every time
///         it is (re)placed (`_inventorySkewBps`), never a static/governed knob.
struct TierConfig {
    uint8 tier; // TIER_STEADY | TIER_ACTIVE
    int24 baseHalfTicks; // wide symmetric base half-width (tier MAGNITUDE fed to the vol multiplier)
    int24 limitHalfTicks; // narrow limit half-width (tier MAGNITUDE fed to the vol multiplier)
    uint16 idleBps; // IDLE reserve target (% of NAV), bounded by IDLE_BPS_MAX
    bool set;
}

struct TrancheState {
    address share; // per-(pool,tranche) ERC-20 clone
    Band[] bands; // disjoint band set (INV-15); length ≤ MAX_BANDS_PER_TRANCHE
    uint256 pending0; // retained 90% fee income (token0)
    uint256 pending1;
    uint256 reserve0; // principal-class holdings not currently banded (idle buffer, recenter dust)
    uint256 reserve1;
    bool exists;
}

struct PoolInfo {
    PoolKey key;
    FeraTypes.Regime regime;
    address oracleFeed; // Chainlink feed (RWA); address(0) for MEME
    uint8 trancheCount;
    bool marketOpen; // keeper-set within on-chain schedule bounds (feeds the hook's RWA fee overlay)
    bool eventWindow; // keeper-flagged scheduled-event session (reserved; no on-chain consumer in v3)
    bool paused; // deposits paused (INV-11)
    bool initialized;
    bool holiday; // keeper holiday flag — force-closes regardless of schedule/flag (mirrors to hook)
    bool quoteIsToken0; // v3.1 unified fee-routing (§9): which side is the liquid QUOTE asset. Immutable.
    uint64 createdAt; // v3.6 (OD-24): block.timestamp at createBaseLimitPool — deliberately NOT derived
        // from the hook's own oracle state (which ordinary swap activity perturbs), so the deposit
        // gate's shallow-history check reflects genuine wall-clock pool age, not "time since the
        // last oracle checkpoint freeze" (a swap-perturbable, much noisier signal).
    uint256 scheduleBitmap; // on-chain UTC weekly calendar (168 bits = hour-of-week; see _isMarketOpen)
}
