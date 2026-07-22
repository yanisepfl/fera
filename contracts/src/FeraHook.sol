// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {IFeraHook} from "./interfaces/IFeraHook.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {FeraTypes} from "./libraries/FeraTypes.sol";
import {FeraConstants} from "./libraries/FeraConstants.sol";
import {FeeLogic} from "./libraries/FeeLogic.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @title FeraHook (v2 — open liquidity + fee-forfeiture JIT guard)
/// @notice The one FERA v4 hook. Open swaps, OPEN liquidity (D-11), regime-priced dynamic fee,
///         economic anti-JIT (D-14, OZ LiquidityPenaltyHook pattern).
/// @dev    INVARIANT MAP:
///          - INV-1″: liquidity ops are permissionless, sender-neutral, never blocked. There is NO
///            before-liquidity gate (the flags are OFF — structural). `afterRemoveLiquidity` NEVER
///            reverts: the JIT guard only forfeits accrued FEES (donated to in-range LPs); principal
///            always exits. Applied identically to every LP including the Vault.
///          - INV-2: beforeSwap NEVER reverts on `sender`, NEVER returns a swap-taking delta, NEVER
///            takes a protocol fee. Enforced *structurally*: the SWAP path carries NO delta flags
///            (beforeSwapReturnDelta / afterSwapReturnDelta are false), so v4-core ignores any swap
///            delta this hook could return — the hook is physically incapable of skimming a swap.
///          - §5: fee is clamped, never reverts a swap for oracle failure / extreme value.
///
///        FLAG SET (MASTER_SPEC §5 v0.5 / D-14 — VERIFIED against v4-core Hooks.sol):
///        {beforeInitialize 0x2000, afterAddLiquidity 0x0400, afterRemoveLiquidity 0x0100,
///         beforeSwap 0x0080, afterSwap 0x0040, afterAddLiquidityReturnDelta 0x0002,
///         afterRemoveLiquidityReturnDelta 0x0001} ⇒ address & 0x3FFF == 0x25C3
///        (= FeraConstants.HOOK_FLAG_TARGET; the 0x25C3 provisional target is CONFIRMED).
///        The deployment salt MUST be CREATE2-mined to that pattern (constructor self-checks via
///        Hooks.validateHookPermissions).
///
///        JIT GUARD MECHANICS (per position key = keccak(owner, tickLower, tickUpper, salt) — the
///        exact v4 position key, so third parties cannot re-arm someone else's clock):
///          - afterAddLiquidity: any add with liquidityDelta > 0 (re)arms the position's window
///            (MEME 1800s / RWA 600s). Fees auto-collected by an add/poke INSIDE the window are
///            WITHHELD in the hook (taken as ERC-6909 claims) so a JIT bot cannot pre-collect via
///            a poke and dodge the exit penalty. Fees collected outside the window pass through.
///          - afterRemoveLiquidity: outside the window ⇒ all withheld fees are returned, penalty 0.
///            Inside the window ⇒ (withheld + newly accrued) fees are forfeited pro-rata to the
///            REMAINING time: penalty = total × (window − elapsed) / window (linear decay,
///            PARAMS.md#JIT_PENALTY_DECAY), donated to in-range LPs via PoolManager.donate. The
///            withdrawer forfeits this amount UNCONDITIONALLY — if no in-range liquidity exists to
///            receive it right now (a JIT LP fully controls its own range and can arrange to be the
///            pool's sole in-range liquidity), the forfeited amount is taken into hook custody instead
///            of donated, and queued for the real donate() at the next add that finds a recipient
///            (`_flushPendingForfeit`); it is never returned to the forfeiting withdrawer. Removal
///            itself NEVER reverts.
contract FeraHook is BaseHook, IFeraHook {
    using BalanceDeltaLibrary for BalanceDelta;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    /// @notice The Vault: pool initializer + strategy owner. NOT a liquidity gate (INV-1″).
    address public immutable vault;

    /// @dev Regime the Vault pre-registers before calling initialize (consumed at beforeInitialize).
    mapping(PoolId => FeraTypes.Regime) internal _pendingRegime;
    mapping(PoolId => bool) internal _pendingSet;

    /// @dev ONE packed per-pool CONFIG slot — the ≤40k RWA beforeSwap reads the whole config in a single
    ///      cold SLOAD (the many-separate-mappings design blew the §5 budget on cold SLOADs; §2.5 assumes
    ///      one config slot). Layout:
    ///        [0,159]  oracleFeed (RWA Chainlink feed; 0 ⇒ MEME/unset ⇒ blind fee) // TODO(chain-confirm): D-9
    ///        [160,167] oracleDecimals (uint8) — cached at setOracleFeed (D-9: per-feed, never assumed),
    ///                  so the swap path never pays a `decimals()` call
    ///        [168]    regime (0=MEME, 1=RWA), bound at init, immutable thereafter
    ///        [170]    sellIsZeroForOne (MEME asymmetric orientation; PARAMS.md#MEME_SELL_IS_ZERO_FOR_ONE)
    ///        [171]    configured (initialized through this hook)
    mapping(PoolId => uint256) internal _cfg;

    /// @dev ONE packed per-pool SCHEDULE slot (MECHANISM_SPEC §2.1 RWA_SCHED_SLOT). Layout:
    ///        [0]     marketOpen (keeper hours flag, mirror of the Vault's — set via FeraVault.setMarketOpen)
    ///        [1]     holiday (keeper flag — force-closes; a keeper can only ever CLOSE, fail-static, §10)
    ///        [2,169] scheduleBitmap (168-bit UTC hour-of-week calendar; bit h = "open at hour-of-week h",
    ///                h = (block.timestamp/3600) % 168, hour 0 = 00:00 UTC Thu). 0 ⇒ keeper flag governs
    ///                (back-compat/fail-static); SET ⇒ bounds the keeper (open ⇔ schedule AND flag, SEC-3 #7).
    mapping(PoolId => uint256) internal _sched;

    /// @dev MEME EWMA state — ONE packed slot per pool (MECHANISM_SPEC §1.3 / PARAMS.md#MEME_STATE_SLOT):
    ///        [0,63] volEwmaX (uint64) | [64,127] flowEwmaX (int64) | [128,151] lastTick (int24)
    ///        | [152,183] lastTs (uint32) | [184,255] free. Updated with 1 SSTORE per swap in afterSwap.
    mapping(PoolId => uint256) internal _memeState;

    uint256 private constant _SCHED_MASK = (uint256(1) << 168) - 1; // 168-bit calendar mask

    // ── packed-config accessors (single-SLOAD reads on the money path) ──────────────────────
    function _regimeOf(PoolId id) internal view returns (FeraTypes.Regime) {
        return FeraTypes.Regime((_cfg[id] >> 168) & 1);
    }

    function _feedOf(PoolId id) internal view returns (address) {
        return address(uint160(_cfg[id]));
    }

    function _decimalsOf(PoolId id) internal view returns (uint8) {
        return uint8(_cfg[id] >> 160);
    }

    function _sellIsZfo(PoolId id) internal view returns (bool) {
        return (_cfg[id] >> 170) & 1 == 1;
    }

    function _isConfiguredSlot(PoolId id) internal view returns (bool) {
        return (_cfg[id] >> 171) & 1 == 1;
    }

    /// @dev Anti-JIT state per (poolId, v4 position key). One slot would need uint64+uint96×2; fees
    ///      can exceed uint96 on 18-dec tokens so we keep uint128 (2 slots, liquidity path only —
    ///      the ≤40k gas budget applies to the SWAP path, which never touches this).
    struct JitState {
        uint64 lastAddTs; // last liquidityDelta>0 timestamp (0 = never)
        uint128 withheld0; // fees withheld in hook custody (ERC-6909 claims)
        uint128 withheld1;
    }

    mapping(PoolId => mapping(bytes32 => JitState)) internal _jit;

    /// @dev Forfeiture queued when a remove found NO in-range liquidity to donate to (the
    ///      sole-in-range-LP edge, `poolManager.getLiquidity(id) == 0` post-removal — a JIT LP fully
    ///      controls its own tickLower/tickUpper and can pick a range/pool where this is always true).
    ///      The withdrawer still forfeits in full at removal time (see `_afterRemoveLiquidity`); only
    ///      the actual `donate()` is deferred, since `donate()` itself reverts on zero liquidity.
    ///      Flushed opportunistically by `_flushPendingForfeit` at the top of the next add — never
    ///      returned to the forfeiting withdrawer.
    mapping(PoolId => uint128) internal _pendingForfeit0;
    mapping(PoolId => uint128) internal _pendingForfeit1;

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Cumulative-tick TWAP oracle (V2-2 / SEC-3 / R-23 — the deposit gate was inert spot before this).
    // v3-lite ring buffer: each write records Σ(tick·dt) up to its timestamp; a same-block swap
    // adds ZERO elapsed time to the accumulator, so a same-tx price push can NOT move the TWAP.
    //
    // R-23 (fast-block window collapse): the ring is written at most ONCE PER TWAP_OBS_SPACING_SEC.
    // Between checkpoints the newest slot is a FLOATING HEAD advanced in place on every swap (keeps
    // the same-block exclusion — a manipulating swap moves head.blockTimestamp to `now`, so the read's
    // `(now − newest.ts)` extrapolation term is 0). New ring slots freeze at spacing boundaries, so
    // OBS_CARDINALITY slots span ~(CARD−1)·SPACING of REAL time (2070s) instead of ~CARD blocks
    // (~2.4s at 100ms). The averaging window therefore reaches the configured 600/1800s.
    // Reads are O(cardinality) (view-only, off the ≤40k swap path). Common-case writes are one warm
    // SSTORE (head advance) + one _lastTick SSTORE; a checkpoint rotation happens only once/spacing.
    // ─────────────────────────────────────────────────────────────────────────────────────
    // MUST equal FeraConstants.TWAP_OBS_CARDINALITY (asserted in test) — a literal here because
    // Solidity requires array lengths to be literal/constant-expression, not a cross-library constant.
    uint16 internal constant OBS_CARDINALITY = 24;

    struct Observation {
        uint32 blockTimestamp; // observation time
        int56 tickCumulative; // Σ tick·dt up to blockTimestamp
        bool initialized;
    }

    mapping(PoolId => Observation[OBS_CARDINALITY]) internal _obs;
    mapping(PoolId => uint16) internal _obsIndex; // index of the most-recent observation (floating head)
    mapping(PoolId => int24) internal _lastTick; // tick effective SINCE the most-recent observation
    mapping(PoolId => uint32) internal _headBornTs; // when the current head slot was frozen/seeded (R-23)

    /// @dev Cap withheld/penalty magnitudes into int128 so delta math can NEVER overflow-revert on
    ///      the remove path (INV-1″: removals never revert, for ANY input).
    uint128 private constant _INT128_MAX = uint128(type(uint128).max >> 1);

    /// @dev Transient slot for handing the beforeSwap fee to afterSwap without SSTORE. keccak namespace.
    bytes32 private constant _T_FEE_SLOT = keccak256("fera.hook.transient.lastFeePips");

    /// @dev PARAMS.md#RWA_ORACLE_TCACHE — per-block transient cache of the RWA oracle read, keyed by
    ///      poolId (§2.5). `_T_ORACLE_BLK` holds `block.number+1` when the value is cached this block so
    ///      0 (tx start, transient cleared) reads as a miss; `_T_ORACLE_VAL` holds the oracleX96 (0 =
    ///      cached fail). Only the FIRST swap of a tx pays the cold Chainlink read; later swaps in the
    ///      same tx (routers/multi-hop/bundles) reuse it. EIP-1153 transient storage is tx-scoped, so the
    ///      amortization is across swaps WITHIN a tx (see OPEN_DECISIONS: cross-tx same-block caching
    ///      would need a block-keyed SSTORE that costs more than the read it saves).
    bytes32 private constant _T_ORACLE_VAL = keccak256("fera.hook.transient.oracleX96");
    bytes32 private constant _T_ORACLE_BLK = keccak256("fera.hook.transient.oracleBlock");

    /// @dev Zero-address guard on the immutable vault wiring (deploy precomputes a real address).
    error ZeroAddress();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(IPoolManager _poolManager, address _vault) BaseHook(_poolManager) {
        if (_vault == address(0)) revert ZeroAddress();
        vault = _vault;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Permission set (v0.5 / D-14). Before-liquidity gates DROPPED (INV-1″); after-liquidity +
    // both after-liquidity return-delta flags ADDED (fee-forfeiture custody). The SWAP path stays
    // delta-flagless (INV-2 structural).
    // ─────────────────────────────────────────────────────────────────────────────────────
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false, // DROPPED (D-14) — liquidity is open (INV-1″)
            afterAddLiquidity: true, // JIT clock + fee withholding
            beforeRemoveLiquidity: false, // DROPPED (D-14) — removals never gated (INV-1″)
            afterRemoveLiquidity: true, // JIT penalty (forfeit-to-donate), never reverts
            beforeSwap: true, // fee override
            afterSwap: true, // accounting event
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false, // MUST stay false — no swap skim (INV-2)
            afterSwapReturnDelta: false, // MUST stay false — no swap skim (INV-2)
            afterAddLiquidityReturnDelta: true, // fee withholding custody
            afterRemoveLiquidityReturnDelta: true // penalty / withheld-fee return
        });
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Vault-driven pool setup: Vault pre-registers the regime, then calls PoolManager.initialize.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IFeraHook
    function registerRegime(PoolKey calldata key, FeraTypes.Regime regime) external onlyVault {
        PoolId id = key.toId();
        _pendingRegime[id] = regime;
        _pendingSet[id] = true;
    }

    /// @inheritdoc IFeraHook
    function setMarketOpen(PoolId id, bool open) external onlyVault {
        uint256 s = _sched[id];
        _sched[id] = open ? s | 1 : s & ~uint256(1);
    }

    /// @inheritdoc IFeraHook
    function setHoliday(PoolId id, bool on) external onlyVault {
        uint256 s = _sched[id];
        _sched[id] = on ? s | 2 : s & ~uint256(2);
    }

    /// @inheritdoc IFeraHook
    function setSchedule(PoolId id, uint256 weeklyBitmap) external onlyVault {
        // Keep the marketOpen/holiday bits; overwrite the 168-bit calendar (masked so a wide input can
        // never bleed into the flag bits).
        _sched[id] = (_sched[id] & 3) | ((weeklyBitmap & _SCHED_MASK) << 2);
    }

    /// @inheritdoc IFeraHook
    function setOracleFeed(PoolId id, address feed) external onlyVault {
        // Clear the feed+decimals half of the config slot, preserve regime/sell/configured (bits ≥168).
        uint256 c = _cfg[id] & ~((uint256(1) << 168) - 1);
        if (feed != address(0)) {
            // Snapshot decimals once (immutable per feed) so the swap path never pays a `decimals()`
            // call. Not a swap path — may revert if the feed is malformed, surfacing it at createPool.
            uint8 dec = IAggregatorV3(feed).decimals();
            c |= uint256(uint160(feed)) | (uint256(dec) << 160);
        }
        _cfg[id] = c;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // beforeInitialize — bind regime + vault, emit PoolRegistered (F-8/BK-2). May revert (not a
    // swap and not a liquidity op — INV-1″/INV-2 untouched).
    // ─────────────────────────────────────────────────────────────────────────────────────
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4) {
        // Pool creation is vault-driven: only the Vault brings a FERA-hooked pool into existence.
        if (sender != vault) revert OnlyVault();
        // The pool MUST be a dynamic-fee pool or our beforeSwap override is silently ignored.
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();

        PoolId id = key.toId();
        if (!_pendingSet[id]) revert PoolNotConfigured();

        FeraTypes.Regime regime = _pendingRegime[id];
        // Read-modify-write the config slot (setOracleFeed may have already written feed+decimals): set
        // regime[168], sellIsZeroForOne[170]=true (canonical §0 orientation: token0=meme/base ⇒ a
        // zeroForOne swap is the LP-toxic SELL; overridable via setSellIsZeroForOne), configured[171].
        // The Vault asserts token ordering at createPool.
        uint256 c = _cfg[id] & ~(uint256(0xF) << 168); // clear regime/sell/configured, keep feed+decimals
        c |= (uint256(uint8(regime)) << 168) | (uint256(1) << 170) | (uint256(1) << 171);
        _cfg[id] = c;
        delete _pendingSet[id];
        delete _pendingRegime[id];

        // Seed the TWAP oracle + the MEME EWMA lastTick at the pool's initial tick so the first swap's
        // realized return r = tick_now − lastTick is a true per-swap move (not a spurious jump from 0),
        // and the deposit gate has a baseline. (A real PoolManager.initialize rejects sqrtPrice 0 before
        // we get here; the guard keeps direct-call unit tests that pass 0 — regime-binding only.)
        if (sqrtPriceX96 != 0) {
            int24 initTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
            _seedOracle(id, initTick);
            _memeState[id] = _packMemeState(0, 0, initTick, uint32(block.timestamp));
        }

        // F-8 event batch (MASTER_SPEC §6 v0.4): the indexer's pool-metadata source of truth.
        emit PoolRegistered(
            PoolId.unwrap(id), Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), uint8(regime)
        );
        return IHooks.beforeInitialize.selector;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // afterAddLiquidity — INV-1″: NEVER gates, NEVER discriminates by sender. Records the JIT
    // clock and withholds in-window auto-collected fees (so a poke cannot pre-collect them).
    // ─────────────────────────────────────────────────────────────────────────────────────
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        // Opportunistically donate any forfeiture that an earlier sole-in-range-LP remove queued —
        // an add is the earliest point a real donation recipient can exist again (D-14 audit fix).
        _flushPendingForfeit(key, id);
        JitState storage j = _jit[id][Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt)];

        BalanceDelta hookDelta = BalanceDeltaLibrary.ZERO_DELTA;

        // Withhold fees auto-collected while the position is inside its own penalty window.
        if (
            j.lastAddTs != 0 && block.timestamp - j.lastAddTs < _jitWindow(id)
                && BalanceDelta.unwrap(feesAccrued) != 0
        ) {
            uint128 f0 = _positive(feesAccrued.amount0());
            uint128 f1 = _positive(feesAccrued.amount1());
            if (f0 != 0) key.currency0.take(poolManager, address(this), f0, true); // ERC-6909 claims
            if (f1 != 0) key.currency1.take(poolManager, address(this), f1, true);
            j.withheld0 = _satAdd(j.withheld0, f0);
            j.withheld1 = _satAdd(j.withheld1, f1);
            hookDelta = toBalanceDelta(int128(f0), int128(f1));
        }

        // (Re)arm the window only on a real add; a pure poke (liquidityDelta == 0) does not.
        if (params.liquidityDelta > 0) j.lastAddTs = uint64(block.timestamp);

        return (IHooks.afterAddLiquidity.selector, hookDelta);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // afterRemoveLiquidity — INV-1″: NEVER reverts. Outside the window: return withheld fees.
    // Inside: forfeit (withheld + accrued) × linear decay, donated to in-range LPs.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        JitState storage j = _jit[id][Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt)];

        uint128 w0 = j.withheld0;
        uint128 w1 = j.withheld1;
        uint64 last = j.lastAddTs;
        uint32 window = _jitWindow(id);

        // Outside the window (or never armed): release custody, zero penalty.
        if (last == 0 || block.timestamp - last >= window) {
            if ((w0 | w1) == 0) return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
            (j.withheld0, j.withheld1) = (0, 0);
            _settleClaims(key, w0, w1);
            // Negative hook delta = credit to the remover (their withheld fees come back).
            return (IHooks.afterRemoveLiquidity.selector, toBalanceDelta(-int128(w0), -int128(w1)));
        }

        // Inside the window: linear-decay forfeiture of everything the position accrued.
        uint256 elapsed = block.timestamp - last;
        uint128 f0 = _positive(feesAccrued.amount0());
        uint128 f1 = _positive(feesAccrued.amount1());
        uint128 t0 = _satAdd(w0, f0);
        uint128 t1 = _satAdd(w1, f1);
        // penalty = total × (window − elapsed) / window — PARAMS.md#JIT_PENALTY_DECAY (linear).
        uint128 p0 = uint128((uint256(t0) * (window - elapsed)) / window);
        uint128 p1 = uint128((uint256(t1) * (window - elapsed)) / window);

        (j.withheld0, j.withheld1) = (0, 0);

        if ((p0 | p1) != 0) {
            if (poolManager.getLiquidity(id) != 0) {
                // Donate the forfeited fees to the remaining in-range LPs (OZ pattern).
                poolManager.donate(key, p0, p1, "");
            } else {
                // No in-range recipient right now (last-withdrawer edge — D-14 audit fix). The
                // withdrawer still forfeits IN FULL: take the penalty into hook custody exactly like
                // the withholding path (`take(...,claims=true)`) instead of skipping it, and queue it
                // for the real `donate()` once this pool has in-range liquidity again
                // (`_flushPendingForfeit`, run at the top of every add). This closes the gap where a
                // JIT LP could pick a pool/range where it is always the sole in-range liquidity to
                // dodge the penalty entirely — the forfeited amount is NEVER returned to them, whether
                // donated now or later.
                if (p0 != 0) key.currency0.take(poolManager, address(this), p0, true);
                if (p1 != 0) key.currency1.take(poolManager, address(this), p1, true);
                _pendingForfeit0[id] = _satAdd(_pendingForfeit0[id], p0);
                _pendingForfeit1[id] = _satAdd(_pendingForfeit1[id], p1);
            }
            emit JitPenaltyApplied(PoolId.unwrap(id), sender, p0, p1);
        }

        // Release custody claims; net hook delta = penalty − withheld per currency:
        //   penalty ≥ withheld ⇒ the difference is charged against the remover's accrued fees;
        //   penalty < withheld ⇒ the non-forfeited remainder is returned to the remover.
        // In every case principal is untouched and the call cannot revert (p ≤ t ≤ int128 max).
        _settleClaims(key, w0, w1);
        return (
            IHooks.afterRemoveLiquidity.selector,
            toBalanceDelta(int128(p0) - int128(w0), int128(p1) - int128(w1))
        );
    }

    /// @dev Burn the hook's ERC-6909 custody claims back to the manager (funds the donation and/or
    ///      the withheld-fee return).
    function _settleClaims(PoolKey calldata key, uint128 a0, uint128 a1) private {
        if (a0 != 0) key.currency0.settle(poolManager, address(this), a0, true);
        if (a1 != 0) key.currency1.settle(poolManager, address(this), a1, true);
    }

    /// @dev Opportunistic flush of forfeiture queued by the no-recipient branch in
    ///      `_afterRemoveLiquidity` (D-14 audit fix). Delta-neutral for the hook — `donate()`'s debit
    ///      is paid off in full by burning the exact claims taken into custody at forfeiture time, the
    ///      same balance as `_settleClaims` uses for the immediate-donation path — so this can NEVER
    ///      revert or block the add (INV-1″). A no-op (two cold reads) when nothing is queued.
    function _flushPendingForfeit(PoolKey calldata key, PoolId id) private {
        uint128 q0 = _pendingForfeit0[id];
        uint128 q1 = _pendingForfeit1[id];
        if ((q0 | q1) == 0 || poolManager.getLiquidity(id) == 0) return;
        (_pendingForfeit0[id], _pendingForfeit1[id]) = (0, 0);
        poolManager.donate(key, q0, q1, "");
        _settleClaims(key, q0, q1);
    }

    /// @dev The regime-scoped JIT penalty window (PARAMS.md#JIT_PENALTY_WINDOW_SEC_{MEME,RWA}).
    function _jitWindow(PoolId id) internal view returns (uint32) {
        return _regimeOf(id) == FeraTypes.Regime.RWA
            ? FeraConstants.JIT_PENALTY_WINDOW_RWA
            : FeraConstants.JIT_PENALTY_WINDOW_MEME;
    }

    function _positive(int128 x) private pure returns (uint128) {
        return x > 0 ? uint128(x) : 0;
    }

    /// @dev Saturating add capped at int128 max — keeps all downstream delta casts revert-free
    ///      (INV-1″ removals-never-revert holds for ANY accounting state).
    function _satAdd(uint128 a, uint128 b) private pure returns (uint128) {
        unchecked {
            uint256 s = uint256(a) + b;
            return s > _INT128_MAX ? _INT128_MAX : uint128(s);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // beforeSwap — OPEN to all senders (INV-2). Returns dynamic LP fee override. NEVER reverts
    // for a `sender`, NEVER returns a swap-taking delta, NEVER takes a protocol fee.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        FeraTypes.Regime regime = _regimeOf(id);

        // Build fee inputs per regime. If the pool is (impossibly) unconfigured, regime reads MEME (0)
        // and the MEME state reads zero ⇒ fee = floor; we still MUST NOT revert (INV-2). Only the RWA
        // path touches the oracle / pool price + market hours; MEME skips them to keep gas tight.
        FeeLogic.FeeInputs memory fi;
        fi.regime = regime;
        if (regime == FeraTypes.Regime.RWA) {
            bool isOpen = _isMarketOpen(id); // computed once; reused for the fee base AND the staleness rule
            fi.marketOpen = isOpen;
            fi.poolPriceX96 = _poolPriceX96(id);
            fi.oraclePriceX96 = _oraclePriceX96Cached(id, isOpen); // 0 ⇒ blind fee, never a revert (INV-2)
        } else {
            (uint256 volX, int256 flowX,,) = _loadMemeState(id);
            fi.volEwmaX = volX;
            fi.flowEwmaX = flowX;
            fi.isSell = (params.zeroForOne == _sellIsZfo(id));
        }

        uint24 lpFeePips = FeeLogic.quoteLpFee(fi);

        // Stash for afterSwap's event without an SSTORE (gas budget ≤ 40k combined, §5).
        _tstoreFee(id, lpFeePips);

        // Return the fee WITH the override flag set (2nd highest bit) so v4-core applies it.
        // ZERO_DELTA + no swap-delta permission ⇒ the hook cannot and does not skim the swap (INV-2).
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // afterSwap — emit the frozen Swap(...) accounting event (MASTER_SPEC §6). Update MEME EWMA.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        _emitSwapEvent(id, sender, params.zeroForOne, delta, _tloadFee(id));

        // One post-swap tick read serves BOTH the TWAP oracle and the MEME EWMA (avoids a 2nd getSlot0).
        (, int24 tick,,) = poolManager.getSlot0(id);
        // Advance the cumulative-tick TWAP oracle from the post-swap tick (V2-2 deposit gate).
        _writeOracle(id, tick);

        // MEME EWMA realized-vol + net-flow update from |Δtick| (MECHANISM_SPEC §1.7). One packed SSTORE.
        // RWA fee is memoryless in the oracle (no afterSwap state), so only MEME pools update here.
        if (_regimeOf(id) == FeraTypes.Regime.MEME) _updateEwma(id, tick);

        return (IHooks.afterSwap.selector, int128(0));
    }

    /// @dev Fresh stack frame keeps the frozen §6 Swap emit under the stack-too-deep limit.
    function _emitSwapEvent(PoolId id, address trader, bool zeroForOne, BalanceDelta delta, uint24 lpFeePips) private {
        int256 amount0 = int256(delta.amount0());
        int256 amount1 = int256(delta.amount1());

        // Input token is the one the trader paid (negative side, swapper's convention).
        // feeAmount = |input| * fee / 1e6. Exact fee accrual is reconciled off-chain from
        // fee-growth in the emissions pipeline (§9); this event field is the on-swap approximation.
        uint256 inputAbs = zeroForOne ? (amount0 < 0 ? uint256(-amount0) : 0) : (amount1 < 0 ? uint256(-amount1) : 0);
        uint256 feeAmount = (inputAbs * lpFeePips) / LPFeeLibrary.MAX_LP_FEE;

        emit Swap(PoolId.unwrap(id), trader, amount0, amount1, lpFeePips, feeAmount, zeroForOne, uint8(_regimeOf(id)));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Internal fee-input sources — the RWA money path (live v4 pool price + Chainlink oracle).
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// @dev Live pool price in X96 basis (token1/token0 · 2^96), read from the v4 pool's sqrtPriceX96
    ///      via StateLibrary.getSlot0. priceX96 = sqrtPriceX96² / 2^96 (FullMath 512-bit, no overflow).
    ///      Never reverts. Compared against `_oraclePriceX96` (same basis) for the RWA deviation overlay.
    function _poolPriceX96(PoolId id) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) return 0;
        return FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
    }

    /// @dev Pool's Chainlink feed price scaled to the SAME X96 basis as `_poolPriceX96`, DECIMALS-AWARE
    ///      per feed (reads decimals(); never assumes 8/18 — D-9). Returns 0 ("unavailable") — which
    ///      FeeLogic maps to the flat blind-pool fee, NEVER a revert (INV-2 / §2.2) — when:
    ///        • no feed is configured, • latestRoundData()/decimals() reverts (try/catch),
    ///        • answer ≤ 0, • or the pool is OPEN and the feed is staler than RWA_STALE_AFTER_OPEN_SEC.
    ///      Off-hours staleness is EXPECTED (the equity feed only prints in-hours) and is NOT a failure —
    ///      the last print is the weekend-drift reference the overlay charges against (§2.2). The
    ///      deposit-gate/recenter staleness (REC-9) is a SEPARATE, stricter check handled in the Vault.
    function _oraclePriceX96(PoolId id, bool isOpen) internal view returns (uint256) {
        address feed = _feedOf(id);
        if (feed == address(0)) return 0;

        try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) return 0; // guard zero/negative answers
            // In-hours staleness ⇒ dead feed ⇒ blind fee. Off-hours staleness is normal (see above).
            if (isOpen && block.timestamp - updatedAt > FeraConstants.RWA_STALE_AFTER_OPEN_SEC) {
                return 0;
            }
            // Normalize the answer to 1e18 using the cached per-feed decimals (D-9), then to X96:
            // answer·10^(18−dec) · 2^96 / 1e18. The overlay uses the RATIO |pool−oracle|/oracle, so the
            // absolute basis cancels; consistency with `_poolPriceX96` is what matters (token
            // decimal/orientation alignment is a deployment responsibility mirrored from the Vault's
            // convention). // TODO(chain-confirm): D-9
            uint256 dec = _decimalsOf(id);
            uint256 norm1e18 =
                dec <= 18 ? uint256(answer) * (10 ** (18 - dec)) : uint256(answer) / (10 ** (dec - 18));
            return FullMath.mulDiv(norm1e18, 1 << 96, 1e18);
        } catch {
            return 0; // feed reverted ⇒ oracle-fail ⇒ blind fee, swap still executes
        }
    }

    /// @dev beforeSwap wrapper around `_oraclePriceX96` with the per-block transient cache
    ///      (PARAMS.md#RWA_ORACLE_TCACHE, §2.5): only the first swap of a tx pays the cold Chainlink read;
    ///      later swaps in the same tx reuse it. Non-view (tstore) so it is NOT used by the getDynamicFee
    ///      view (which reads the feed directly).
    function _oraclePriceX96Cached(PoolId id, bool isOpen) private returns (uint256 px) {
        bytes32 blkSlot = keccak256(abi.encode(_T_ORACLE_BLK, id));
        bytes32 valSlot = keccak256(abi.encode(_T_ORACLE_VAL, id));
        uint256 cachedBlk;
        assembly ("memory-safe") {
            cachedBlk := tload(blkSlot)
        }
        if (cachedBlk == block.number + 1) {
            assembly ("memory-safe") {
                px := tload(valSlot)
            }
            return px;
        }
        px = _oraclePriceX96(id, isOpen); // cold read
        uint256 mark = block.number + 1;
        assembly ("memory-safe") {
            tstore(valSlot, px)
            tstore(blkSlot, mark)
        }
    }

    /// @dev Market-hours check for the RWA fee overlay — mirrors FeraVault._isMarketOpen so the fee and
    ///      the strategy agree on "open" (§2.1). Fail-static order: (1) keeper holiday force-closes;
    ///      (2) keeper hours flag; (3) the on-chain 168-bit UTC weekly calendar (0 ⇒ keeper flag governs;
    ///      a SET calendar bounds the keeper — open ⇔ schedule AND flag agree). Pure arithmetic + SLOADs.
    function _isMarketOpen(PoolId id) internal view returns (bool) {
        uint256 s = _sched[id]; // single SLOAD: holiday | marketOpen | 168-bit calendar
        if (s & 2 != 0) return false; // (1) keeper holiday — force close
        if (s & 1 == 0) return false; // (2) keeper hours flag
        uint256 sched = (s >> 2) & _SCHED_MASK;
        if (sched == 0) return true; // (3) no calendar ⇒ keeper flag governs (back-compat)
        // slither-disable-next-line weak-prng — hour-of-week calendar index (modulo), not randomness.
        uint256 hourOfWeek = (block.timestamp / 3_600) % 168;
        return (sched >> hourOfWeek) & 1 == 1;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // MEME EWMA realized-vol + net-flow estimator (MECHANISM_SPEC §1.2/§1.7). ONE packed SSTORE.
    // ─────────────────────────────────────────────────────────────────────────────────────

    /// @dev Per-swap EWMA update from the realized log-return r = tick_now − lastTick (ticks ≈ bps):
    ///        target = r²
    ///        λ = target > EWMA(r²) ? LAMBDA_UP(fast attack) : LAMBDA_DOWN(slow release)  — the ratchet
    ///        volEwmaX ← clamp((λ·volEwmaX + (ONE−λ)·(r²<<16)) >> 16, 0, VOL_CLAMP)
    ///        λ_f = r < EWMA(r) ? FLOW_ATTACK(unchanged, toward more negative) : FLOW_RELEASE(slow,
    ///              toward positive) — an asymmetric ratchet applied BY SIGN (not magnitude, unlike
    ///              vol): the attack side is left at the ORIGINAL pre-fix decay (ordinary selling
    ///              behaves exactly as before); only the release side is slowed (v3.5 fix: a
    ///              symmetric flow decay let one priming buy erase accumulated sell pressure as fast
    ///              as a sell built it — see MEME_FLOW_LAMBDA_ATTACK/_RELEASE).
    ///        flowEwmaX ← (λ_f·flowEwmaX + (ONE−λ_f)·(clamp(r, ±R_CLAMP if release)<<16)) >> 16
    ///      Vol's attack/release makes it spike in ~1–2 swaps but bleed off over tens (defeats the
    ///      decay-then-dump exploit); flow's asymmetry protects against a cheap priming-buy fee-dodge
    ///      without changing how it reacts to ordinary selling. The release branch ADDITIONALLY
    ///      clamps the raw sample `r` before blending (v3.6 fix, open-kritt finding): the tiny
    ///      release weight alone does not bound a single swap's influence, since it multiplies the
    ///      UN-normalized `r`, which is bounded only by the pool's tick range — a large enough
    ///      one-shot `r` still flips flowEwmaX's sign regardless of accumulated magnitude. Clamping
    ///      `r` restores the "single offsetting swap can't erase built-up sell pressure" guarantee
    ///      the v3.5 fix intended (see MEME_FLOW_RELEASE_R_CLAMP_TICKS NatSpec). Never reverts; all
    ///      intermediates in uint256/int256, downcast + clamp.
    function _updateEwma(PoolId id, int24 tickNow) internal {
        (uint256 volX, int256 flowX, int24 lastTick,) = _loadMemeState(id);

        int256 r = int256(tickNow) - int256(lastTick);
        uint256 r2 = uint256(r * r); // ≤ ~3.15e12 for the full tick range; r²<<16 fits uint256
        uint256 ONE = FeraConstants.MEME_ONE;

        uint256 lam = (r2 > (volX >> 16)) ? FeraConstants.MEME_VOL_LAMBDA_UP : FeraConstants.MEME_VOL_LAMBDA_DOWN;
        uint256 newVol = (lam * volX + (ONE - lam) * (r2 << 16)) >> 16;
        if (newVol > FeraConstants.MEME_VOL_CLAMP) newVol = FeraConstants.MEME_VOL_CLAMP;

        // Signed arithmetic-shift descale (Solidity 0.8.x rounds `>>` toward -infinity for signed
        // ints, consistent with the fixed-point convention used throughout this estimator).
        bool isAttack = r < (flowX >> 16);
        int256 lamF = isAttack ? int256(FeraConstants.MEME_FLOW_LAMBDA_ATTACK) : int256(FeraConstants.MEME_FLOW_LAMBDA_RELEASE);
        // v3.6 FIX (audit finding, open-kritt): clamp the RELEASE branch's raw sample so a single
        // large swap cannot dominate the slow release weight and flip flowEwmaX's sign in one shot
        // (see MEME_FLOW_RELEASE_R_CLAMP_TICKS NatSpec). The ATTACK branch is untouched — ordinary
        // selling behaves exactly as before.
        int256 rForFlow = r;
        if (!isAttack) {
            int256 clamp = int256(FeraConstants.MEME_FLOW_RELEASE_R_CLAMP_TICKS);
            if (rForFlow > clamp) rForFlow = clamp;
            else if (rForFlow < -clamp) rForFlow = -clamp;
        }
        int256 newFlow = (lamF * flowX + (int256(ONE) - lamF) * (rForFlow << 16)) >> 16;

        _memeState[id] = _packMemeState(newVol, _toInt64Sat(newFlow), tickNow, uint32(block.timestamp));
    }

    /// @dev Unpack the MEME state slot (§1.3). Signed fields recovered via narrow int casts.
    function _loadMemeState(PoolId id)
        internal
        view
        returns (uint256 volX, int256 flowX, int24 lastTick, uint32 lastTs)
    {
        uint256 s = _memeState[id];
        volX = uint256(uint64(s));
        flowX = int256(int64(uint64(s >> 64)));
        lastTick = int24(uint24(uint256(s >> 128)));
        lastTs = uint32(uint256(s >> 152));
    }

    /// @dev Pack the MEME state slot (§1.3): volEwmaX≤2^50 fits uint64; flow pre-saturated to int64.
    function _packMemeState(uint256 volX, int256 flowX, int24 tickNow, uint32 ts) internal pure returns (uint256) {
        return uint256(uint64(volX)) | (uint256(uint64(int64(flowX))) << 64) | (uint256(uint24(tickNow)) << 128)
            | (uint256(ts) << 152);
    }

    /// @dev Saturate an int256 into int64 range so packing can never truncate-corrupt the flow field
    ///      (EWMA keeps |flow| far below int64 max in practice; this is a belt-and-braces guard).
    function _toInt64Sat(int256 x) internal pure returns (int256) {
        if (x > type(int64).max) return type(int64).max;
        if (x < type(int64).min) return type(int64).min;
        return x;
    }

    // ── cumulative-tick TWAP oracle (V2-2 / SEC-3 / R-23) ───────────────────────────────
    /// @dev Seed the ring at pool init so a baseline observation exists immediately.
    function _seedOracle(PoolId id, int24 tick) internal {
        uint32 nowTs = uint32(block.timestamp);
        _obs[id][0] = Observation({blockTimestamp: nowTs, tickCumulative: 0, initialized: true});
        _obsIndex[id] = 0;
        _lastTick[id] = tick;
        _headBornTs[id] = nowTs;
    }

    /// @dev Advance the accumulator to `now` using the tick that was effective SINCE the last
    ///      observation. The newest slot is a FLOATING HEAD advanced IN PLACE on every swap; a new
    ///      ring slot is frozen only once TWAP_OBS_SPACING_SEC has elapsed since the current head was
    ///      born (R-23 — extends the effective window on fast-block chains). A same-block swap adds 0
    ///      elapsed time (dt == 0), so it can never move a windowed TWAP read in the same block/tx:
    ///      the read extrapolates by `_lastTick·(now − head.ts)` and head.ts was already advanced to
    ///      `now` by the first swap of the block, zeroing that term.
    function _writeOracle(PoolId id, int24 tick) internal {
        uint16 idx = _obsIndex[id];
        Observation storage head = _obs[id][idx];
        uint32 nowTs = uint32(block.timestamp);
        if (!head.initialized) {
            _seedOracle(id, tick);
            return;
        }
        // TASK-1 / MUST-FIX (v3-hardening 2026-07-14): the cumulative-tick oracle math runs UNCHECKED,
        // exactly like the Uniswap v3/v4 reference Oracle. Two overflow classes are wrapped away here:
        //   • the uint32 elapsed-time subtractions (`nowTs - head.blockTimestamp`, `nowTs -
        //     _headBornTs`) wrap mod 2^32 — correct as long as the TRUE elapsed span < 2^32s. A
        //     block.timestamp crossing the uint32 rollover (or a test warping across it) would make
        //     the CHECKED subtraction underflow-panic (0x11).
        //   • the int56 accumulation (`tickCumulative + _lastTick·dt`) wraps mod 2^56 — every consumer
        //     (`consultTwapTick`) differences two cumulatives, so a consistent wrap cancels exactly.
        // `_writeOracle` runs inside `afterSwap`; a panic here would REVERT THE TRIGGERING SWAP,
        // violating INV-2 ("swaps never revert"). Wrapping arithmetic can NEVER revert, so afterSwap
        // is now unconditionally revert-free on this path.
        unchecked {
            uint32 dt = nowTs - head.blockTimestamp;
            if (dt == 0) {
                _lastTick[id] = tick; // same block: only the effective tick for the NEXT interval moves
                return;
            }

            // Advance the cumulative to `now` using the tick effective over [head.ts, now]. This uses
            // _lastTick as it stood entering this interval (set by the PREVIOUS swap), NOT the current
            // (possibly manipulated) `tick` — so an atomic manipulate-then-restore never enters history.
            int56 cumNow = head.tickCumulative + int56(_lastTick[id]) * int56(uint56(dt));

            if (nowTs - _headBornTs[id] >= FeraConstants.TWAP_OBS_SPACING_SEC) {
                // Spacing elapsed: FREEZE the current head as a checkpoint and open a new floating head
                // at the next slot (continuing from the same cumulative). Checkpoints are therefore ≥
                // SPACING apart, so the ring spans real time, not blocks.
                _obs[id][idx] = Observation({blockTimestamp: nowTs, tickCumulative: cumNow, initialized: true});
                uint16 next = (idx + 1) % OBS_CARDINALITY;
                _obs[id][next] = Observation({blockTimestamp: nowTs, tickCumulative: cumNow, initialized: true});
                _obsIndex[id] = next;
                _headBornTs[id] = nowTs;
            } else {
                // Within the spacing window: advance the head IN PLACE (no new checkpoint). Keeps
                // (now − head.ts) small so the read's live-tick extrapolation stays negligible.
                head.blockTimestamp = nowTs;
                head.tickCumulative = cumNow;
            }
            _lastTick[id] = tick;
        }
    }

    /// @inheritdoc IFeraHook
    function consultTwapTick(PoolId id, uint32 window) external view returns (int24 twapTick, bool ready) {
        uint16 idx = _obsIndex[id];
        Observation storage newest = _obs[id][idx];
        if (!newest.initialized) return (0, false);

        uint32 nowTs = uint32(block.timestamp);
        // TASK-1 / MUST-FIX (v3-hardening 2026-07-14): UNCHECKED to match the Uniswap v3/v4 reference
        // Oracle — the uint32 elapsed-time subtraction and the int56 accumulation wrap-around, and the
        // final `cumNow - anchorCum` delta below differences two cumulatives so the wrap cancels
        // exactly (the true average tick always fits int24). CHECKED arithmetic could panic (0x11) at
        // the uint32 timestamp rollover or on an extreme cumulative; this view feeds `_poolTwapPrice`,
        // which the deposit + rebalance gates call WITHOUT a try/catch — a panic there would DoS them.
        // Wrapping cannot panic, so a bad/edge read degrades to `ready=false` (spot fallback) or the
        // fail-closed stale path in the consumer, never an uncaught revert.
        int56 cumNow;
        unchecked {
            cumNow = newest.tickCumulative + int56(_lastTick[id]) * int56(uint56(nowTs - newest.blockTimestamp));
        }

        uint32 targetTs = window >= nowTs ? 0 : nowTs - window;

        // Anchor = the newest observation at-or-before targetTs; if none that old, the OLDEST one.
        // No interpolation: TWAP spans [anchor, now] (≥ window when history is deep enough).
        bool haveAnchor;
        uint32 anchorTs;
        int56 anchorCum;
        uint32 oldestTs = type(uint32).max;
        int56 oldestCum;
        for (uint16 i; i < OBS_CARDINALITY; ++i) {
            Observation storage o = _obs[id][i];
            if (!o.initialized) continue;
            if (o.blockTimestamp < oldestTs) {
                oldestTs = o.blockTimestamp;
                oldestCum = o.tickCumulative;
            }
            if (o.blockTimestamp <= targetTs && (!haveAnchor || o.blockTimestamp > anchorTs)) {
                haveAnchor = true;
                anchorTs = o.blockTimestamp;
                anchorCum = o.tickCumulative;
            }
        }
        if (!haveAnchor) {
            anchorTs = oldestTs;
            anchorCum = oldestCum;
        }
        if (nowTs <= anchorTs) return (0, false); // no elapsed history ⇒ caller falls back to spot
        unchecked {
            // `cumNow - anchorCum` differences two (possibly-wrapped) int56 cumulatives; the wrap
            // cancels so the quotient is the true average tick (fits int24). `nowTs - anchorTs` is
            // guaranteed > 0 by the guard above, so the division is safe.
            twapTick = int24((cumNow - anchorCum) / int56(uint56(nowTs - anchorTs)));
        }
        ready = true;
    }

    /// @inheritdoc IFeraHook
    /// @dev REC-9 fail-closed input: how stale the newest observation is. The newest slot is the
    ///      floating head, advanced to `now` on every swap — so a live pool reports age 0 and only a
    ///      dormant pool (no swaps for a while) reports a large age. Consumers revert their
    ///      strategy/deposit-gate path when this exceeds TWAP_MAX_STALENESS_SEC (never the swap path).
    function twapObservationAge(PoolId id) external view returns (uint32 ageSec, bool hasObservation) {
        Observation storage newest = _obs[id][_obsIndex[id]];
        if (!newest.initialized) return (0, false);
        uint32 nowTs = uint32(block.timestamp);
        ageSec = nowTs > newest.blockTimestamp ? nowTs - newest.blockTimestamp : 0;
        hasObservation = true;
    }

    /// @inheritdoc IFeraHook
    /// @dev Audit finding (open-kritt, OD-17): `consultTwapTick`'s `ready` flag only requires >0
    ///      seconds of elapsed time — it can be TRUE from a single very-recent floating-head
    ///      observation with no real window-spanning history (e.g. right after a pool's first-ever
    ///      swap, before the first checkpoint has had TWAP_OBS_SPACING_SEC to freeze), making the
    ///      returned "TWAP" collapse to whatever tick the most recent swap just set. This scans the
    ///      ring for the OLDEST initialized checkpoint so a caller can require genuine depth (compare
    ///      the returned age against its own desired window) before trusting a TWAP-anchored bound.
    function oldestObservationAge(PoolId id) external view returns (uint32 ageSec, bool hasObservation) {
        uint32 oldestTs = type(uint32).max;
        for (uint16 i; i < OBS_CARDINALITY; ++i) {
            Observation storage o = _obs[id][i];
            if (!o.initialized) continue;
            hasObservation = true;
            if (o.blockTimestamp < oldestTs) oldestTs = o.blockTimestamp;
        }
        if (!hasObservation) return (0, false);
        uint32 nowTs = uint32(block.timestamp);
        ageSec = nowTs > oldestTs ? nowTs - oldestTs : 0;
    }

    // ── transient fee handoff (EIP-1153) ────────────────────────────────────────────────
    function _tstoreFee(PoolId id, uint24 fee) private {
        bytes32 slot = keccak256(abi.encode(_T_FEE_SLOT, id));
        assembly ("memory-safe") {
            tstore(slot, fee)
        }
    }

    function _tloadFee(PoolId id) private view returns (uint24 fee) {
        bytes32 slot = keccak256(abi.encode(_T_FEE_SLOT, id));
        assembly ("memory-safe") {
            fee := tload(slot)
        }
    }

    // ── IFeraHook views ──────────────────────────────────────────────────────────────────
    function regimeOf(PoolId poolId) external view returns (FeraTypes.Regime) {
        return _regimeOf(poolId);
    }

    /// @inheritdoc IFeraHook
    /// @dev F-12: quotes the live fee via the SAME `FeeLogic.quoteLpFee` inputs `beforeSwap` builds
    ///      (regime, market-hours flag, EWMA vol, pool/oracle price), fixing `zeroForOne=false` so the
    ///      returned value is the non-directional (buy-side) base fee. Pure/view, no state change;
    ///      FeeLogic never reverts and clamps into the regime [floor, ceil].
    function getDynamicFee(PoolId poolId) external view returns (uint24 lpFeePips) {
        FeraTypes.Regime regime = _regimeOf(poolId);
        FeeLogic.FeeInputs memory fi;
        fi.regime = regime;
        if (regime == FeraTypes.Regime.RWA) {
            bool isOpen = _isMarketOpen(poolId);
            fi.marketOpen = isOpen;
            fi.poolPriceX96 = _poolPriceX96(poolId);
            fi.oraclePriceX96 = _oraclePriceX96(poolId, isOpen); // direct read (no transient cache in a view)
        } else {
            (uint256 volX, int256 flowX,,) = _loadMemeState(poolId);
            fi.volEwmaX = volX;
            fi.flowEwmaX = flowX;
            fi.isSell = false; // buy-side base fee; the asymmetric sell adder is added on the sell side
        }
        return FeeLogic.quoteLpFee(fi);
    }

    /// @inheritdoc IFeraHook
    function isMarketOpen(PoolId poolId) external view returns (bool) {
        return _isMarketOpen(poolId);
    }

    /// @inheritdoc IFeraHook
    function memeStateOf(PoolId poolId)
        external
        view
        returns (uint256 volEwmaX, int256 flowEwmaX, int24 lastTick, uint32 lastTs)
    {
        return _loadMemeState(poolId);
    }

    /// @inheritdoc IFeraHook
    function setSellIsZeroForOne(PoolId id, bool sellIsZeroForOne_) external onlyVault {
        uint256 c = _cfg[id];
        _cfg[id] = sellIsZeroForOne_ ? c | (uint256(1) << 170) : c & ~(uint256(1) << 170);
    }

    function isConfigured(PoolId poolId) external view returns (bool) {
        return _isConfiguredSlot(poolId);
    }

    function jitPenaltyWindow(PoolId poolId) external view returns (uint32) {
        return _jitWindow(poolId);
    }

    function jitStateOf(PoolId poolId, bytes32 positionKey)
        external
        view
        returns (uint64 lastAddTs, uint128 withheld0, uint128 withheld1)
    {
        JitState storage j = _jit[poolId][positionKey];
        return (j.lastAddTs, j.withheld0, j.withheld1);
    }

    /// @inheritdoc IFeraHook
    function pendingForfeitOf(PoolId poolId) external view returns (uint128 pending0, uint128 pending1) {
        return (_pendingForfeit0[poolId], _pendingForfeit1[poolId]);
    }
}
