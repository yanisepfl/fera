// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FeraTypes} from "../libraries/FeraTypes.sol";

/// @title IFeraVault (v2 — band ladders + risk tranches, D-12/D-15..18)
/// @notice The managed-liquidity layer: per-pool band ladders across ≤2 risk tranches, each tranche
///         an independent ERC-20 share class over a DISJOINT band set (INV-15). Deposits are
///         ratio-matched + TWAP-gated + cooled-down (Gamma hardening); fee collection skims exactly
///         10% per tranche (INV-3); MEME strategy is principal-passive drip (kind=5) plus the
///         guarded principal recenter (INV-5″); RWA strategy is oracle-anchored within on-chain
///         verified bounds (INV-6, PT-6/PT-7 frozen). Deposit-only pause (INV-11).
///         MASTER_SPEC §3, §6 (F-8 batch: `uint8 tranche` fields + kind=5).
interface IFeraVault {
    // ── Events (frozen MASTER_SPEC §6 + F-8 batch: `uint8 tranche` appended) ───────────────
    event Deposit(
        bytes32 indexed poolId,
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint256 sharesMinted,
        uint8 tranche
    );
    event Withdraw(
        bytes32 indexed poolId,
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint256 sharesBurned,
        uint8 tranche
    );
    event FeesCollected(
        bytes32 indexed poolId, uint256 fee0, uint256 fee1, uint256 perfFee0, uint256 perfFee1, uint8 tranche
    );
    event StrategyAction(
        bytes32 indexed poolId,
        uint8 kind, // 0=initialMint 1=recenter 2=widen 3=partialWithdraw 4=compoundInPlace 5=dripDeploy
        int24 tickLower,
        int24 tickUpper,
        uint256 oraclePrice,
        bytes32 justificationHash
    );
    event SharePriceCheckpoint(bytes32 indexed poolId, uint256 sharePriceX96, uint256 epochId, uint8 tranche); // INV-4
    /// @notice Emitted when the owner (timelock) rotates the strategy keeper.
    event KeeperUpdated(address indexed keeper);

    // ── Errors ───────────────────────────────────────────────────────────────────────────
    error ZeroAddress(); // zero-address rejected on keeper setter + immutable ctor wiring
    error DepositsPaused(); // INV-11 (deposits ONLY — withdrawals are never pausable)
    error CooldownActive(); // PARAMS.md#DEPOSIT_COOLDOWN_SEC — depositor's OWN fresh shares
    error TwapGateExceeded(); // PARAMS.md#DEPOSIT_TWAP_GATE_BPS — deposits revert outside the gate
    error GateOutOfBounds(); // setter outside the immutable [50,500]bp legal range (Gamma lesson)
    error NotMeme(); // MEME-only action (drip / guarded recenter / depth poke)
    error NotRwa(); // RWA-only action (oracle recenter / widen / partialWithdraw)
    error DepthNotBreached(); // INV-5″: at-spot depth ≥ 1.0× v1-full-range equivalent
    error BreachNotPersistent(); // INV-5″: breach younger than MEME_RECENTER_PERSIST_SEC (24h)
    error RecenterTooSoon(); // INV-5″ 7d / PT-6 RWA 4h minimum interval
    error ValueSlippage(); // INV-5″: recenter value conservation beyond MEME_RECENTER_MAX_SLIPPAGE_BPS
    error WithdrawFracExceeded(); // PT-7: RWA partial withdraw above the q-bound
    error DripTooSoon(); // PARAMS.md#MEME_DRIP_MIN_INTERVAL_SEC
    error DripTooSmall(); // PARAMS.md#MEME_DRIP_MIN_SIZE_BPS
    error MarketClosed();
    error MarketOpen();
    error OracleStale();
    error TwapOutOfBand();
    /// @notice REC-9 fail-closed: the pool's newest TWAP observation is older than TWAP_MAX_STALENESS_SEC
    ///         (a dormant pool) — the deposit gate + recenter TWAP-sanity legs revert rather than trust a
    ///         stale, near-spot extrapolation. NEVER on the swap path (INV-2). A single swap re-arms it.
    error TwapStale();
    error HysteresisNotMet();
    error LaunchpadDisabled();
    error OnlyKeeper();
    error Slippage();
    error UnknownPool();
    error UnknownTranche();
    error ZeroDeposit();

    /// @notice Deposit into a tranche of `poolId`, ratio-matched across its band ladder; mints the
    ///         tranche's ERC-20 shares at NAV. Respects pause + TWAP gate (INV-11 — pausable side).
    function deposit(PoolId poolId, uint8 tranche, uint256 amount0, uint256 amount1, uint256 minShares)
        external
        returns (uint256 sharesMinted);

    /// @notice Burn `shares` of a tranche pro-rata across its bands (+ held balances). NEVER
    ///         pausable (INV-11); only the depositor's own 1h cooldown applies.
    function withdraw(PoolId poolId, uint8 tranche, uint256 shares, uint256 minAmount0, uint256 minAmount1)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Checkpoint a tranche: poke its bands, realize fees, skim EXACTLY 10% to the
    ///         RevenueDistributor (INV-3 per tranche, INV-15), retain 90% as drip income.
    function collectFees(PoolId poolId, uint8 tranche)
        external
        returns (uint256 fee0, uint256 fee1, uint256 perfFee0, uint256 perfFee1);

    /// @notice Pure split preview — perfFee = 10% of fee, lpFee = remainder. Used by INV-3 tests.
    function previewPerfFee(uint256 fee0, uint256 fee1)
        external
        pure
        returns (uint256 perfFee0, uint256 perfFee1, uint256 lpFee0, uint256 lpFee1);

    /// @notice MEME drip (StrategyAction kind=5): deploy retained fee income as a no-swap
    ///         single-sided limit band (Charm pattern), consolidating per D-17. onlyKeeper.
    function drip(PoolId poolId, uint8 tranche) external;

    /// @notice Record / refresh the INV-5″ depth-breach clock. Permissionless (it can only make
    ///         recentering STRICTER — clearing a stale breach or arming a real one).
    function pokeDepthBreach(PoolId poolId) external returns (bool breached);

    /// @notice Guarded MEME principal recenter (INV-5″). Keeper triggers; the contract re-verifies
    ///         ALL of: depth breach sustained ≥24h, ≥7d since last, TWAP sanity, value conservation.
    function recenterMeme(PoolId poolId, bytes32 justificationHash) external;

    /// @notice RWA oracle-anchored recenter (INV-6 + PT-6 min interval). onlyKeeper.
    function recenter(PoolId poolId, int24 newTickLower, int24 newTickUpper, bytes32 justificationHash) external;

    /// @notice RWA off-hours widen. onlyKeeper.
    function widen(PoolId poolId, int24 newTickLower, int24 newTickUpper, bytes32 justificationHash) external;

    /// @notice RWA off-hours partial de-risk, bounded by q (0.60; 0.80 in a keeper-flagged event
    ///         session — PT-7/D-M11). Core tranche only; Anchor is exempt (already wide). onlyKeeper.
    function partialWithdraw(PoolId poolId, uint128 liquidityToPull, bytes32 justificationHash) external;

    /// @notice Compound retained fee income into a tranche's primary band (kind=4). onlyKeeper.
    function compound(PoolId poolId, uint8 tranche, bytes32 justificationHash) external;

    // ── Views ────────────────────────────────────────────────────────────────────────────
    /// @notice The per-(pool, tranche) ERC-20 share token address.
    function shareToken(PoolId poolId, uint8 tranche) external view returns (address);

    /// @notice The regime bound to `poolId`.
    function regimeOf(PoolId poolId) external view returns (FeraTypes.Regime);

    /// @notice Whether `poolId`'s underlying market is currently OPEN, per the same fail-static
    ///         holiday → keeper-flag → on-chain schedule logic the RWA strategy gate enforces
    ///         (`_isMarketOpen`). MEME pools read `true` while their keeper flag is up. Read-only
    ///         mirror of the internal gate — F-12 (Backend marketHours/rwaStrategy keepers).
    function isMarketOpen(PoolId poolId) external view returns (bool open);

    /// @notice Whether a keeper-flagged scheduled-event session (D-M11) is active on `poolId`
    ///         (raises the off-hours partial-withdraw cap 0.60 → 0.80). F-12 (Backend eventCalendar).
    function isEventWindow(PoolId poolId) external view returns (bool active);

    /// @notice Whether deposits are paused for `poolId`.
    function depositsPaused(PoolId poolId) external view returns (bool);

    /// @notice Number of tranches on `poolId` (MEME 1, RWA 2 — D-16).
    function trancheCount(PoolId poolId) external view returns (uint8);

    /// @notice Number of live bands in a tranche (≤ MEME_MAX_BANDS_PER_TRANCHE).
    function bandCount(PoolId poolId, uint8 tranche) external view returns (uint256);

    /// @notice Band descriptor (ticks, liquidity, principal-vs-fee class — D-17).
    function bandAt(PoolId poolId, uint8 tranche, uint256 index)
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, bool isPrincipal);

    /// @notice Retained (90%) fee income awaiting drip, per tranche.
    function pendingFees(PoolId poolId, uint8 tranche) external view returns (uint256 pending0, uint256 pending1);

    /// @notice First-breach timestamp of the INV-5″ depth condition (0 = not breached).
    function depthBreachSince(PoolId poolId) external view returns (uint64);
}
