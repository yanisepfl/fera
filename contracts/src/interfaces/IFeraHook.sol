// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FeraTypes} from "../libraries/FeraTypes.sol";

/// @title IFeraHook
/// @notice The FERA v4 hook, v2 (D-11/D-14). Binds regime at init (vault-driven) and emits
///         `PoolRegistered`; liquidity is PERMISSIONLESS (INV-1″ — no add/remove gate, removals
///         never revert); anti-JIT is economic: a fee-forfeiture penalty window (OZ
///         LiquidityPenaltyHook pattern) donates early-removers' accrued fees to in-range LPs;
///         overrides the dynamic LP fee in beforeSwap; emits compact accounting in afterSwap.
///         MASTER_SPEC §3, §5 (v0.5 flag set), §6 (F-8 batch) and INV-1″ / INV-2.
interface IFeraHook {
    // ── Events ───────────────────────────────────────────────────────────────────────────
    /// @dev EXACT signature per MASTER_SPEC §6 (field names, types, indexed markers frozen).
    event Swap(
        bytes32 indexed poolId,
        address indexed trader, // the swap `sender` (router or EOA)
        int256 amount0, // signed, pool convention
        int256 amount1,
        uint24 lpFeePips, // dynamic fee actually applied
        uint256 feeAmount, // LP fee taken this swap, in the input token
        bool zeroForOne, // swap direction
        uint8 regime // Regime at time of swap
    );

    /// @notice Emitted in beforeInitialize when a pool binds its regime (F-8 / BK-2 — the indexer's
    ///         pool-metadata source of truth). EXACT signature per MASTER_SPEC §6 v0.4 batch.
    event PoolRegistered(bytes32 indexed poolId, address token0, address token1, uint8 regime);

    /// @notice Emitted when an early remove forfeits accrued fees to in-range LPs (D-14 / INV-1″).
    ///         EXACT signature per MASTER_SPEC §6 v0.4 batch.
    event JitPenaltyApplied(bytes32 indexed poolId, address indexed owner, uint256 fee0Forfeited, uint256 fee1Forfeited);

    // ── Errors ───────────────────────────────────────────────────────────────────────────
    error OnlyVault(); // pool INITIALIZATION is vault-driven (liquidity is NOT gated — INV-1″)
    error PoolNotConfigured();
    error NotDynamicFeePool();

    /// @notice Called by the Vault BEFORE `PoolManager.initialize` to declare the pool's regime.
    /// @dev    onlyVault (setup path, not a liquidity gate); consumed & cleared at beforeInitialize.
    function registerRegime(PoolKey calldata key, FeraTypes.Regime regime) external;

    /// @notice Keeper/Vault flips the RWA market-hours flag within on-chain bounds. onlyVault.
    /// @dev    The hook only consumes the flag as a fee input; it never gates a swap on it (INV-2).
    function setMarketOpen(PoolId poolId, bool open) external;

    /// @notice Keeper holiday flag mirror (force-closes the RWA fee overlay's "open"). onlyVault.
    function setHoliday(PoolId poolId, bool on) external;

    /// @notice On-chain UTC weekly calendar mirror: 168-bit hour-of-week bitmap (0 ⇒ keeper flag
    ///         governs). Bounds the keeper — open ⇔ schedule AND flag agree (§2.1 / SEC-3 #7). onlyVault.
    function setSchedule(PoolId poolId, uint256 weeklyBitmap) external;

    /// @notice Bind the pool's Chainlink feed for the RWA deviation overlay (createPool oracle arg).
    /// @dev    onlyVault; address(0) ⇒ no oracle ⇒ blind fee. Decimals read per-feed at use (D-9).
    function setOracleFeed(PoolId poolId, address feed) external;

    /// @notice Set the MEME asymmetric-sell orientation (PARAMS.md#MEME_SELL_IS_ZERO_FOR_ONE). onlyVault.
    /// @dev    Default true (canonical token0=meme ordering); override if a pool is quoted inverted.
    function setSellIsZeroForOne(PoolId poolId, bool sellIsZeroForOne) external;

    /// @notice Whether the RWA market is open for `poolId` right now (holiday ∧ keeper-flag ∧ calendar).
    ///         MEME pools ignore this input. Never reverts.
    function isMarketOpen(PoolId poolId) external view returns (bool);

    /// @notice The live MEME EWMA state slot, unpacked: EWMA(r²)·2^16, signed EWMA(r)·2^16, last tick,
    ///         last update ts. For off-chain reconciliation of the dynamic fee (MASTER §9).
    function memeStateOf(PoolId poolId)
        external
        view
        returns (uint256 volEwmaX, int256 flowEwmaX, int24 lastTick, uint32 lastTs);

    /// @notice Regime bound to `poolId` at initialization (immutable post-init).
    function regimeOf(PoolId poolId) external view returns (FeraTypes.Regime);

    /// @notice F-12: the LP fee (pips) the hook would quote for `poolId` RIGHT NOW on a non-directional
    ///         (buy-side) swap, i.e. the current regime dynamic fee before the MEME asymmetric
    ///         sell-side surcharge. Same `FeeLogic.quoteLpFee` path `beforeSwap` uses, so it reflects
    ///         the live regime / market-hours / EWMA-vol state. Never reverts; clamped into the regime
    ///         [floor, ceil]. For the API live-fee read + reconcile (dynamic-fee pools expose no
    ///         readable slot0 lpFee). Sells additionally carry `MEME_SELL_SURCHARGE_BPS`.
    function getDynamicFee(PoolId poolId) external view returns (uint24 lpFeePips);

    /// @notice The Vault (pool initializer + strategy owner). NOT a liquidity gate (INV-1″).
    function vault() external view returns (address);

    /// @notice Whether `poolId` has been initialized through this hook.
    function isConfigured(PoolId poolId) external view returns (bool);

    /// @notice The JIT penalty window for `poolId` (regime-dependent: MEME 1800s / RWA 600s).
    function jitPenaltyWindow(PoolId poolId) external view returns (uint32);

    /// @notice Manipulation-resistant arithmetic-mean tick over roughly the last `window` seconds,
    ///         from the hook's cumulative-tick oracle (seeded at init, advanced in afterSwap).
    /// @dev    Used by the Vault deposit gate + RWA/MEME recenter TWAP-sanity legs (V2-2 / INV-5″ /
    ///         INV-6). Same-block swaps contribute ZERO elapsed time to the accumulator, so a
    ///         flash/same-tx price push cannot move the returned TWAP (the Gamma defence).
    /// @return twapTick arithmetic-mean tick over [now-window, now] (capped at available history).
    /// @return ready    false until at least one second of history exists (caller treats as spot).
    function consultTwapTick(PoolId poolId, uint32 window) external view returns (int24 twapTick, bool ready);

    /// @notice Age (seconds) of the newest TWAP observation = `now − newest.blockTimestamp`, used by
    ///         the manipulation-sensitive consumers (deposit gate + recenter) to FAIL-CLOSED on a
    ///         dormant pool whose reading is a stale extrapolation (REC-9 / convergence N4/N5).
    /// @return ageSec         seconds since the newest observation (0 if none yet).
    /// @return hasObservation false until the ring is seeded (fresh pool ⇒ consumers fall back to spot).
    function twapObservationAge(PoolId poolId) external view returns (uint32 ageSec, bool hasObservation);

    /// @notice Withheld (in-custody) fees + last-add timestamp for a position's JIT state.
    /// @dev    Keyed exactly like v4 positions: (owner=sender, tickLower, tickUpper, salt) — the
    ///         review-verified keying that makes third-party dust-griefing impossible.
    function jitStateOf(PoolId poolId, bytes32 positionKey)
        external
        view
        returns (uint64 lastAddTs, uint128 withheld0, uint128 withheld1);
}
