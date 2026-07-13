// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IFeraVault} from "./interfaces/IFeraVault.sol";
import {IFeraShare} from "./interfaces/IFeraShare.sol";
import {IFeraHook} from "./interfaces/IFeraHook.sol";
import {IRevenueDistributor} from "./interfaces/IRevenueDistributor.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {FeraTypes} from "./libraries/FeraTypes.sol";
import {FeraConstants} from "./libraries/FeraConstants.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeraVault (v2 — band ladders + risk tranches; docs/VAULT_ARCHITECTURE.md v2.1)
/// @notice The managed-liquidity layer of FERA. Per pool the Vault runs a small band LADDER
///         (MEME: 30/40/30 at k=1.3 / 2.0 / full-range; RWA: tight oracle-anchored Core + wide
///         static Anchor) across ≤2 risk TRANCHES, each an independent per-pool ERC-20 share class
///         over a DISJOINT band set (INV-15). Under open liquidity (D-11) anyone may LP directly;
///         the Vault's exclusive carrot is emissions (INV-14) — enforced off-chain from these events.
/// @dev    INVARIANT MAP:
///          - INV-3  : `collectFees`/`_checkpoint` skim EXACTLY 10% of collected fees per tranche;
///            principal never enters the fee path.
///          - INV-5″ : MEME principal moves ONLY through `recenterMeme`, which re-verifies ON-CHAIN:
///            depth < 1.0× v1-full-range-equivalent sustained ≥24h (stored first-breach ts), ≥7d
///            since the last recenter, pool-TWAP sanity ±5%, and ≤100bp value slippage. Drip
///            (kind=5) deploys FEE INCOME ONLY as no-swap single-sided bands, with D-17
///            consolidation + the hard MEME_MAX_BANDS_PER_TRANCHE=8 cap.
///          - INV-6  : RWA recenter re-verifies oracle hysteresis ∧ market open ∧ TWAP sanity, plus
///            the PT-6 frozen 4h minimum interval.
///          - INV-11 : deposits pausable + TWAP-gated (revertable); withdrawals NEVER pausable —
///            only the depositor's own 1h cooldown (Veda share-lock, PARAMS §D2) applies.
///          - INV-15 : every band belongs to exactly one tranche; all callback actions are
///            tranche-scoped; v4 position SALTS are tranche-scoped (D-18) so positions can never
///            merge across tranches; fees checkpoint into the owning tranche only.
///          - D-18   : fee-checkpoint-before-mint — every deposit/withdraw/drip first pokes the
///            tranche's bands (v4 auto-collects on modifyLiquidity, so mints would otherwise
///            misprice); the JIT guard (INV-1″) applies to the Vault exactly like any other LP.
contract FeraVault is IFeraVault, IUnlockCallback, Ownable, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IFeraHook public immutable hook;
    IRevenueDistributor public immutable revenueDistributor;
    address public immutable shareImplementation; // FeraShare impl for EIP-1167 cloning
    address public keeper;

    /// @dev Locked forever on first deposit (per tranche) to defuse share-inflation (R-12).
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant WAD = 1e18;

    /// @notice PARAMS.md#DEPOSIT_TWAP_GATE_BPS — timelocked-owner-settable WITHIN the immutable
    ///         [50,500]bp legal range hardcoded in `setDepositTwapGate` (the Gamma lesson).
    uint256 public depositTwapGateBps = FeraConstants.DEPOSIT_TWAP_GATE_DEFAULT_BPS;

    struct Band {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool isPrincipal; // D-17: principal bands vs fee-funded (drip) bands
        uint16 weightBps; // ladder weight (principal bands; used at first mint + recenter)
    }

    struct TrancheState {
        address share; // per-(pool,tranche) ERC-20 clone
        Band[] bands; // disjoint band set (INV-15); length ≤ MEME_MAX_BANDS_PER_TRANCHE
        uint256 pending0; // retained 90% fee income awaiting drip/compound (token0)
        uint256 pending1;
        uint256 reserve0; // principal-class holdings not currently banded (RWA de-risk, recenter dust)
        uint256 reserve1;
        uint64 lastDripTs;
        bool exists;
    }

    struct PoolInfo {
        PoolKey key;
        FeraTypes.Regime regime;
        address oracleFeed; // Chainlink feed (RWA); address(0) for MEME
        uint8 trancheCount;
        bool marketOpen; // keeper-set within on-chain schedule bounds
        bool eventWindow; // keeper-flagged scheduled-event session (D-M11; fail-static)
        bool paused; // deposits paused (INV-11)
        bool initialized;
        bool holiday; // keeper holiday flag — force-closes regardless of schedule/flag (§10)
        uint256 scheduleBitmap; // on-chain UTC weekly calendar (168 bits = hour-of-week; see _isMarketOpen)
        uint64 lastRwaRecenterTs; // PT-6 (frozen 14400s) — ENFORCED
        uint64 lastMemeRecenterTs; // INV-5″ 7d interval
        uint64 depthBreachSince; // INV-5″ first-breach timestamp (0 = not breached)
        uint256 lastRecenterOracle; // RWA hysteresis basis
    }

    mapping(PoolId => PoolInfo) internal pools;
    mapping(PoolId => mapping(uint256 => TrancheState)) internal tranches;
    /// @dev PARAMS.md#DEPOSIT_COOLDOWN_SEC: per-(pool,tranche,user) last deposit; blocks only that
    ///      user's own redemption for 1h (narrow — no INV-11 tension).
    mapping(PoolId => mapping(uint256 => mapping(address => uint64))) public lastDepositTs;

    // Callback action tags.
    uint8 internal constant CB_CHECKPOINT = 0; // poke bands, realize fees to the Vault
    uint8 internal constant CB_FIRST_DEPOSIT = 1; // weight-split initial ladder mint
    uint8 internal constant CB_DEPOSIT = 2; // pro-rata (ratio-matched) ladder add
    uint8 internal constant CB_WITHDRAW = 3; // pro-rata ladder remove, pay user
    uint8 internal constant CB_ADD_TO_BAND = 4; // fee income into an existing band (kind=4)
    uint8 internal constant CB_NEW_BAND = 5; // fee income into a new single-sided band (kind=5)
    uint8 internal constant CB_RECENTER_MEME = 6; // INV-5″ guarded principal recenter
    uint8 internal constant CB_REBALANCE_RWA = 7; // RWA recenter/widen of the Core band
    uint8 internal constant CB_PULL = 8; // RWA partial withdraw into reserves

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }

    modifier notPaused(PoolId id) {
        if (pools[id].paused) revert DepositsPaused();
        _;
    }

    modifier knownTranche(PoolId id, uint8 t) {
        if (!pools[id].initialized) revert UnknownPool();
        if (t >= pools[id].trancheCount) revert UnknownTranche();
        _;
    }

    constructor(
        IPoolManager poolManager_,
        IFeraHook hook_,
        IRevenueDistributor revenueDistributor_,
        address shareImplementation_,
        address keeper_,
        address timelockOwner
    ) Ownable(timelockOwner) {
        if (shareImplementation_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        hook = hook_;
        revenueDistributor = revenueDistributor_;
        shareImplementation = shareImplementation_;
        keeper = keeper_;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Pool lifecycle — creates pool, clones per-tranche shares, defines the band ladder.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Register + initialize a FERA pool; deploy its tranche share tokens; define the
    ///         ladder. MEME: single Core tranche, 3 principal bands 30/40/30 at k=1.3/2.0/full
    ///         (D-16). RWA: Core (tight, oracle-anchored) + Anchor (wide, static). onlyKeeper.
    function createPool(
        PoolKey calldata key,
        FeraTypes.Regime regime,
        address oracleFeed,
        uint160 sqrtPriceX96,
        string calldata name_,
        string calldata symbol_
    ) external onlyKeeper returns (PoolId id) {
        id = key.toId();
        PoolInfo storage p = pools[id];
        require(!p.initialized, "init");

        // 1) Tell the hook the regime + oracle feed, then initialize (hook.beforeInitialize binds +
        //    emits PoolRegistered per F-8). The feed powers the hook's RWA deviation overlay (§2.3).
        hook.registerRegime(key, regime);
        hook.setOracleFeed(id, oracleFeed);
        poolManager.initialize(key, sqrtPriceX96);

        p.key = key;
        p.regime = regime;
        p.oracleFeed = oracleFeed;
        p.marketOpen = regime == FeraTypes.Regime.MEME; // MEME "always open"; RWA keeper-flagged
        p.initialized = true;

        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 spacing = key.tickSpacing;

        if (regime == FeraTypes.Regime.MEME) {
            // PARAMS.md#MEME_TRANCHE_COUNT = 1 (D-16).
            p.trancheCount = FeraConstants.MEME_TRANCHE_COUNT;
            TrancheState storage core = tranches[id][0];
            core.exists = true;
            core.share = _cloneShare(id, name_, symbol_, 0);
            (int24 lo, int24 hi) = _bandAround(tick, FeraConstants.MEME_LADDER_CORE_TICKS, spacing);
            _pushBand(core, lo, hi, true, uint16(FeraConstants.MEME_LADDER_CORE_WEIGHT_BPS));
            (lo, hi) = _bandAround(tick, FeraConstants.MEME_LADDER_MID_TICKS, spacing);
            _pushBand(core, lo, hi, true, uint16(FeraConstants.MEME_LADDER_MID_WEIGHT_BPS));
            (lo, hi) = _fullRange(spacing);
            _pushBand(core, lo, hi, true, uint16(FeraConstants.MEME_LADDER_TAIL_WEIGHT_BPS));
            emit StrategyAction(
                PoolId.unwrap(id), uint8(FeraTypes.StrategyKind.InitialMint), core.bands[0].tickLower, core.bands[0].tickUpper, 0, bytes32(0)
            );
        } else {
            // RWA: Core (tranche 0, tight) + Anchor (tranche 1, wide static) — D-16.
            p.trancheCount = FeraConstants.RWA_TRANCHE_COUNT;
            TrancheState storage core = tranches[id][0];
            core.exists = true;
            core.share = _cloneShare(id, name_, symbol_, 0);
            (int24 lo, int24 hi) = _bandAround(tick, FeraConstants.RWA_BAND_HALF_WIDTH_TICKS, spacing);
            _pushBand(core, lo, hi, true, uint16(FeraConstants.BPS));

            TrancheState storage anchor = tranches[id][1];
            anchor.exists = true;
            anchor.share = _cloneShare(id, name_, symbol_, 1);
            (lo, hi) = _bandAround(tick, FeraConstants.RWA_ANCHOR_BAND_HALF_WIDTH_TICKS, spacing);
            _pushBand(anchor, lo, hi, true, uint16(FeraConstants.BPS));

            emit StrategyAction(
                PoolId.unwrap(id), uint8(FeraTypes.StrategyKind.InitialMint), core.bands[0].tickLower, core.bands[0].tickUpper, 0, bytes32(0)
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Deposit / Withdraw (per tranche) — hardened per PARAMS §D2 (OD-V5 / Gamma vector)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraVault
    function deposit(PoolId id, uint8 t, uint256 amount0, uint256 amount1, uint256 minShares)
        external
        nonReentrant
        notPaused(id) // INV-11: deposits pausable
        knownTranche(id, t)
        returns (uint256 sharesMinted)
    {
        PoolInfo storage p = pools[id];
        if (amount0 == 0 && amount1 == 0) revert ZeroDeposit();

        // Gamma hardening #1: spot-vs-TWAP gate (bounds live in code — see setDepositTwapGate).
        if (_twapDeviationBps(id, FeraConstants.DEPOSIT_TWAP_WINDOW_SEC) > depositTwapGateBps) {
            revert TwapGateExceeded();
        }

        // Pull user funds; the callback settles them to the manager. Leftover refunded.
        if (amount0 != 0) IERC20(Currency.unwrap(p.key.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) IERC20(Currency.unwrap(p.key.currency1)).safeTransferFrom(msg.sender, address(this), amount1);

        // Gamma hardening #3 / D-18: fee-checkpoint BEFORE the mint so NAV excludes unrealized fees.
        _checkpoint(id, t);

        TrancheState storage tr = tranches[id][t];
        uint256 totalShares = IFeraShare(tr.share).totalSupply();
        uint256 used0;
        uint256 used1;

        if (totalShares == 0) {
            // First deposit: mint the ladder at its frozen weights; lock MINIMUM_LIQUIDITY (R-12).
            uint256 sumDL;
            (sumDL, used0, used1) = abi.decode(
                poolManager.unlock(abi.encode(CB_FIRST_DEPOSIT, id, t, abi.encode(amount0, amount1))),
                (uint256, uint256, uint256)
            );
            require(sumDL > MINIMUM_LIQUIDITY, "min-liq");
            sharesMinted = sumDL - MINIMUM_LIQUIDITY;
            IFeraShare(tr.share).mint(DEAD, MINIMUM_LIQUIDITY);
        } else {
            // Gamma hardening #2 (ratio-matched, PARAMS.md#DEPOSIT_RATIO_MATCHED) + R-18/INV-16 full-NAV
            // pricing + REC-10 rounding. Extracted to a helper to keep this frame under via_ir's stack
            // limit; see `_mintNonFirst` for the (added-liquidity ∧ net-paid) min-valuation rationale.
            (sharesMinted, used0, used1) = _mintNonFirst(id, t, amount0, amount1, totalShares);
        }
        if (sharesMinted < minShares || sharesMinted == 0) revert Slippage();

        // Gamma hardening #4: cooldown on the depositor's OWN fresh shares (Veda lock) — enforced on
        // BOTH the withdraw path (below) and, per V2-2 (SEC-3 #4), on outgoing SHARE TRANSFERS so
        // the cooldown cannot be dodged by moving fresh shares to a second wallet.
        lastDepositTs[id][t][msg.sender] = uint64(block.timestamp);
        IFeraShare(tr.share).setTransferLock(msg.sender, uint64(block.timestamp) + FeraConstants.DEPOSIT_COOLDOWN_SEC);

        IFeraShare(tr.share).mint(msg.sender, sharesMinted);

        // Refund any un-deployed remainder to the user. Clamp to zero (R-18 memo / SEC-3 audit fix):
        // v4 rounds the amount owed UP against the LP, so the actual `used` can exceed the estimate
        // by a few wei when the Vault also holds pending/reserve balances in the same currency —
        // `amount - used` would then underflow-revert a legitimate deposit. The ≤dust overshoot is
        // sourced from tranche reserves and rounds against the depositor (conservative).
        _refund(p.key.currency0, msg.sender, amount0 > used0 ? amount0 - used0 : 0);
        _refund(p.key.currency1, msg.sender, amount1 > used1 ? amount1 - used1 : 0);

        emit Deposit(PoolId.unwrap(id), msg.sender, used0, used1, sharesMinted, t);
    }

    /// @dev Non-first-deposit share pricing (extracted for stack depth). Adds the ratio-matched
    ///      liquidity, then prices the mint against the FULL tranche NAV (R-18/INV-16: banded value +
    ///      pending + reserve, so mint-NAV == redeem-NAV — pricing off banded liquidity alone would
    ///      over-mint and skim pending/reserve from existing holders). REC-10: the mint value is the
    ///      MINIMUM of two floored quantities, each rounding against the depositor:
    ///        (a) `dV = navAfter − navBefore` — the value of the liquidity actually credited, floored the
    ///            SAME way `_trancheValue`/the withdraw path value bands (NOT off `used`, which v4 rounds
    ///            UP on mint). An add moves neither spot nor pending/reserve, so dV is exact.
    ///        (b) `netPaid` — value of `min(amount_j, used_j)` per currency, the depositor's real outlay.
    ///            When v4's mint round-up makes `used_j > amount_j`, the overshoot is covered from tranche
    ///            reserve (see the deposit `_refund` clamp), so pricing on dV alone reserve-SUBSIDISES the
    ///            depositor — the ≤4-wei round-trip leak (convergence N6). Capping at netPaid removes it.
    ///      ⇒ a deposit→withdraw round trip can never return more than deposited (INV-16 residual = 0).
    function _mintNonFirst(PoolId id, uint8 t, uint256 amount0, uint256 amount1, uint256 totalShares)
        internal
        returns (uint256 sharesMinted, uint256 used0, uint256 used1)
    {
        (uint256 navBefore, uint160 sqrtPriceX96,) = _trancheValue(id, t);
        require(navBefore != 0, "empty");

        (,, used0, used1) = abi.decode(
            poolManager.unlock(abi.encode(CB_DEPOSIT, id, t, abi.encode(amount0, amount1))),
            (uint256, uint256, uint256, uint256)
        );

        // REC-10 reconciliation: v4's mint round-up may pull a few wei MORE than the depositor provided
        // (`used_j > amount_j`). That overage physically comes out of the tranche's OWN reserve/pending
        // token balances, but nothing decremented the reserve/pending ACCOUNTING — so NAV would be
        // overstated by that dust and paid out pro-rata to every holder (the ≤4-wei round-trip leak,
        // convergence N6). Decrement the accounting to match the physical spend so `navAfter` is honest.
        _absorbDepositOverage(tranches[id][t], used0 > amount0 ? used0 - amount0 : 0, used1 > amount1 ? used1 - amount1 : 0);

        (uint256 navAfter,,) = _trancheValue(id, t);
        // dV = the reconciled NAV increase (added-liquidity value net of any reserve-funded overage),
        // floored the SAME way the withdraw path values bands. Cap by net-paid value belt-and-suspenders.
        uint256 dV = navAfter - navBefore;
        uint256 netPaid =
            _valueInToken1(sqrtPriceX96, amount0 < used0 ? amount0 : used0, amount1 < used1 ? amount1 : used1);
        // Round DOWN (against the depositor — R-17 ratchet discipline). mint-NAV == redeem-NAV.
        sharesMinted = FullMath.mulDiv(dV < netPaid ? dV : netPaid, totalShares, navBefore);
    }

    /// @dev Subtract a v4 mint-round-up overage (in token terms) from a tranche's non-banded holdings,
    ///      reserve first then pending, each floored at 0 — keeps the reserve/pending ACCOUNTING equal
    ///      to the physical token balance after the overage was spent (REC-10 / INV-16). Dust-sized.
    function _absorbDepositOverage(TrancheState storage tr, uint256 over0, uint256 over1) internal {
        if (over0 != 0) {
            uint256 fromR = over0 < tr.reserve0 ? over0 : tr.reserve0;
            tr.reserve0 -= fromR;
            uint256 rem = over0 - fromR;
            if (rem != 0) tr.pending0 = tr.pending0 > rem ? tr.pending0 - rem : 0;
        }
        if (over1 != 0) {
            uint256 fromR = over1 < tr.reserve1 ? over1 : tr.reserve1;
            tr.reserve1 -= fromR;
            uint256 rem = over1 - fromR;
            if (rem != 0) tr.pending1 = tr.pending1 > rem ? tr.pending1 - rem : 0;
        }
    }

    /// @inheritdoc IFeraVault
    /// @dev NEVER pausable (INV-11): no `notPaused` modifier here, by design. The only constraint
    ///      is the withdrawer's OWN deposit cooldown (PARAMS §D2 — kills flash-loan round trips).
    function withdraw(PoolId id, uint8 t, uint256 shares, uint256 minAmount0, uint256 minAmount1)
        external
        nonReentrant
        knownTranche(id, t)
        returns (uint256 amount0, uint256 amount1)
    {
        if (block.timestamp < lastDepositTs[id][t][msg.sender] + FeraConstants.DEPOSIT_COOLDOWN_SEC) {
            revert CooldownActive();
        }

        // D-18: realize fees first so the exiting shares are paid at a fee-checkpointed NAV and
        // the burn cannot strand unrealized fees with the leavers/stayers asymmetrically.
        _checkpoint(id, t);

        TrancheState storage tr = tranches[id][t];
        uint256 totalShares = IFeraShare(tr.share).totalSupply();

        // Pro-rata slice of held (non-banded) balances — ALL rounding DOWN (against the
        // withdrawer; R-17 ratchet discipline: dust stays with remaining holders, never leaves).
        uint256 heldOut0;
        uint256 heldOut1;
        {
            uint256 dPending0 = FullMath.mulDiv(shares, tr.pending0, totalShares);
            uint256 dPending1 = FullMath.mulDiv(shares, tr.pending1, totalShares);
            uint256 dReserve0 = FullMath.mulDiv(shares, tr.reserve0, totalShares);
            uint256 dReserve1 = FullMath.mulDiv(shares, tr.reserve1, totalShares);
            tr.pending0 -= dPending0;
            tr.pending1 -= dPending1;
            tr.reserve0 -= dReserve0;
            tr.reserve1 -= dReserve1;
            heldOut0 = dPending0 + dReserve0;
            heldOut1 = dPending1 + dReserve1;
        }

        // Burn FIRST (CEI), then realize the banded withdrawal via the callback.
        IFeraShare(tr.share).burn(msg.sender, shares);

        (uint256 out0, uint256 out1) = abi.decode(
            poolManager.unlock(abi.encode(CB_WITHDRAW, id, t, abi.encode(shares, totalShares, msg.sender))),
            (uint256, uint256)
        );

        amount0 = out0 + heldOut0;
        amount1 = out1 + heldOut1;
        _refund(pools[id].key.currency0, msg.sender, heldOut0);
        _refund(pools[id].key.currency1, msg.sender, heldOut1);

        if (amount0 < minAmount0 || amount1 < minAmount1) revert Slippage();
        emit Withdraw(PoolId.unwrap(id), msg.sender, amount0, amount1, shares, t);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Fee collection — EXACTLY 10% perf skim PER TRANCHE (INV-3 / INV-15)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraVault
    function collectFees(PoolId id, uint8 t)
        external
        nonReentrant
        knownTranche(id, t)
        returns (uint256 fee0, uint256 fee1, uint256 perfFee0, uint256 perfFee1)
    {
        (fee0, fee1, perfFee0, perfFee1) = _checkpoint(id, t);
    }

    /// @dev Poke the tranche's bands (realizing fees), skim EXACTLY 10%, retain 90% as pending
    ///      drip income. INV-15: only tranche `t`'s bands are poked; only its pending is credited.
    ///      NOTE: what arrives may be less than fees accrued if the Vault's own band is inside the
    ///      hook's JIT window (INV-1″ applies to the Vault too) — accounting is actual-receipts.
    function _checkpoint(PoolId id, uint8 t)
        internal
        returns (uint256 fee0, uint256 fee1, uint256 perfFee0, uint256 perfFee1)
    {
        (fee0, fee1) = abi.decode(poolManager.unlock(abi.encode(CB_CHECKPOINT, id, t, bytes(""))), (uint256, uint256));

        uint256 lpFee0;
        uint256 lpFee1;
        (perfFee0, perfFee1, lpFee0, lpFee1) = previewPerfFee(fee0, fee1);

        PoolInfo storage p = pools[id];
        _routePerfFee(p.key.currency0, perfFee0);
        _routePerfFee(p.key.currency1, perfFee1);

        TrancheState storage tr = tranches[id][t];
        tr.pending0 += lpFee0;
        tr.pending1 += lpFee1;

        emit FeesCollected(PoolId.unwrap(id), fee0, fee1, perfFee0, perfFee1, t);
        _emitSharePriceCheckpoint(id, t);
    }

    /// @inheritdoc IFeraVault
    /// @dev Pure. perfFee = floor(fee * 10%); lpFee = fee - perfFee (remainder-to-LP). Exactly 10%
    ///      of collected fees, 0% of principal — principal never enters this function.
    function previewPerfFee(uint256 fee0, uint256 fee1)
        public
        pure
        returns (uint256 perfFee0, uint256 perfFee1, uint256 lpFee0, uint256 lpFee1)
    {
        perfFee0 = (fee0 * FeraConstants.PERF_FEE_BPS) / FeraConstants.BPS;
        perfFee1 = (fee1 * FeraConstants.PERF_FEE_BPS) / FeraConstants.BPS;
        lpFee0 = fee0 - perfFee0;
        lpFee1 = fee1 - perfFee1;
    }

    function _routePerfFee(Currency c, uint256 amount) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(c);
        IERC20(token).safeTransfer(address(revenueDistributor), amount);
        revenueDistributor.notifyRevenue(token, amount);
    }

    function _emitSharePriceCheckpoint(PoolId id, uint8 t) internal {
        TrancheState storage tr = tranches[id][t];
        uint256 supply = IFeraShare(tr.share).totalSupply();
        if (supply == 0) return;
        (uint256 v,,) = _trancheValue(id, t);
        // epochId derived from the frozen EPOCH_LENGTH; Backend reconciles against the controller.
        emit SharePriceCheckpoint(
            PoolId.unwrap(id), FullMath.mulDiv(v, 1 << 96, supply), block.timestamp / FeraConstants.EPOCH_LENGTH, t
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // MEME drip (kind=5) — INV-5″ fee-active leg. No swap anywhere; principal untouched.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraVault
    function drip(PoolId id, uint8 t) external onlyKeeper nonReentrant knownTranche(id, t) {
        PoolInfo storage p = pools[id];
        if (p.regime != FeraTypes.Regime.MEME) revert NotMeme();
        TrancheState storage tr = tranches[id][t];
        if (block.timestamp < tr.lastDripTs + FeraConstants.MEME_DRIP_MIN_INTERVAL_SEC) revert DripTooSoon();

        _checkpoint(id, t);

        // Size gate: pending fee income ≥ MEME_DRIP_MIN_SIZE_BPS of tranche TVL (both in token1).
        (uint256 tvl, uint160 sqrtPriceX96, int24 tick) = _trancheValue(id, t);
        uint256 pendingValue = _valueInToken1(sqrtPriceX96, tr.pending0, tr.pending1);
        if (pendingValue * FeraConstants.BPS < tvl * FeraConstants.MEME_DRIP_MIN_SIZE_BPS) revert DripTooSmall();

        tr.lastDripTs = uint64(block.timestamp);

        // D-17 consolidation: an existing FEE band centered within ±10% of spot absorbs the drip
        // (kind=4). At the band cap the NEAREST fee band absorbs it regardless of distance.
        (bool found, uint256 idx) =
            _consolidationTarget(tr, tick, tr.bands.length >= FeraConstants.MEME_MAX_BANDS_PER_TRANCHE);
        if (found) {
            (uint256 used0, uint256 used1) = abi.decode(
                poolManager.unlock(abi.encode(CB_ADD_TO_BAND, id, t, abi.encode(idx, tr.pending0, tr.pending1))),
                (uint256, uint256)
            );
            tr.pending0 -= used0;
            tr.pending1 -= used1;
            // F-9 (D-17): a drip MERGED into an existing fee band is a band consolidation (kind=6),
            // NOT a keeper compound-in-place (kind=4). Backend distinguishes them off-chain.
            emit StrategyAction(
                PoolId.unwrap(id),
                uint8(FeraTypes.StrategyKind.BandConsolidate),
                tr.bands[idx].tickLower,
                tr.bands[idx].tickUpper,
                0,
                bytes32(0)
            );
            return;
        }

        // New single-sided no-swap limit band on the EXCESS-token side (Charm pattern).
        bool side0 = _valueInToken1(sqrtPriceX96, tr.pending0, 0) >= tr.pending1;
        int24 spacing = p.key.tickSpacing;
        int24 lower;
        int24 upper;
        if (side0) {
            // token0 deploys ABOVE spot: [P, k·P].
            lower = _ceilTick(tick, spacing) + spacing;
            upper = lower + _floorTick(FeraConstants.MEME_DRIP_BAND_TICKS, spacing);
        } else {
            // token1 deploys BELOW spot: [P/k, P].
            upper = _floorTick(tick, spacing);
            lower = upper - _floorTick(FeraConstants.MEME_DRIP_BAND_TICKS, spacing);
        }

        (uint128 dL, uint256 u0, uint256 u1) = abi.decode(
            poolManager.unlock(
                abi.encode(CB_NEW_BAND, id, t, abi.encode(lower, upper, side0 ? tr.pending0 : 0, side0 ? 0 : tr.pending1))
            ),
            (uint128, uint256, uint256)
        );
        tr.pending0 -= u0;
        tr.pending1 -= u1;
        if (dL != 0) {
            Band memory b = Band({tickLower: lower, tickUpper: upper, liquidity: dL, isPrincipal: false, weightBps: 0});
            tr.bands.push(b);
            emit StrategyAction(PoolId.unwrap(id), uint8(FeraTypes.StrategyKind.DripDeploy), lower, upper, 0, bytes32(0));
        }
    }

    function _consolidationTarget(TrancheState storage tr, int24 tick, bool atCap)
        internal
        view
        returns (bool found, uint256 idx)
    {
        int256 best = type(int256).max;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            if (b.isPrincipal) continue; // principal bands are NEVER a drip sink (INV-5″/D-17)
            int256 center = (int256(b.tickLower) + int256(b.tickUpper)) / 2;
            int256 dist = center > int256(tick) ? center - int256(tick) : int256(tick) - center;
            if (dist < best) {
                best = dist;
                idx = i;
                found = atCap || dist <= int256(FeraConstants.MEME_DRIP_CONSOLIDATE_TICKS);
            }
        }
        if (!atCap && found) return (true, idx);
        if (atCap && best != type(int256).max) return (true, idx);
        return (false, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Guarded MEME principal recenter — INV-5″. Keeper triggers; the CONTRACT verifies.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraVault
    /// @dev Permissionless on purpose: recording a breach (or clearing a stale one) only makes the
    ///      recenter gate STRICTER-or-armed; execution still re-verifies everything.
    function pokeDepthBreach(PoolId id) public returns (bool breached) {
        PoolInfo storage p = pools[id];
        if (!p.initialized) revert UnknownPool();
        if (p.regime != FeraTypes.Regime.MEME) revert NotMeme();
        breached = _depthBreached(id);
        if (breached) {
            if (p.depthBreachSince == 0) p.depthBreachSince = uint64(block.timestamp);
        } else {
            p.depthBreachSince = 0;
        }
    }

    /// @inheritdoc IFeraVault
    function recenterMeme(PoolId id, bytes32 justificationHash) external onlyKeeper nonReentrant {
        PoolInfo storage p = pools[id];
        if (!p.initialized) revert UnknownPool();
        if (p.regime != FeraTypes.Regime.MEME) revert NotMeme();

        // Gate 1 — depth breach, re-verified NOW (not just at the last poke).
        if (!_depthBreached(id)) revert DepthNotBreached();
        // Gate 2 — sustained ≥ 24h (PARAMS.md#MEME_RECENTER_PERSIST_SEC) from the stored first-breach.
        uint64 since = p.depthBreachSince;
        if (since == 0 || block.timestamp - since < FeraConstants.MEME_RECENTER_PERSIST_SEC) {
            revert BreachNotPersistent();
        }
        // Gate 3 — ≥ 7d since the last recenter (PARAMS.md#MEME_MIN_RECENTER_INTERVAL_SEC).
        if (p.lastMemeRecenterTs != 0 && block.timestamp - p.lastMemeRecenterTs < FeraConstants.MEME_MIN_RECENTER_INTERVAL_SEC)
        {
            revert RecenterTooSoon();
        }
        // Gate 4 — pool TWAP within ±5% of spot (PARAMS.md#MEME_RECENTER_TWAP_SANITY_BPS).
        if (_twapDeviationBps(id, FeraConstants.MEME_RECENTER_TWAP_WINDOW_SEC) > FeraConstants.MEME_RECENTER_TWAP_SANITY_BPS)
        {
            revert TwapOutOfBand();
        }

        // Fees first (v4 auto-collect would otherwise blend fees into principal — D-18).
        _checkpoint(id, 0);

        // Gate 5 — execution value conservation ≤ 100bp (PARAMS.md#MEME_RECENTER_MAX_SLIPPAGE_BPS).
        (uint256 valueBefore,,) = _trancheValue(id, 0);
        poolManager.unlock(abi.encode(CB_RECENTER_MEME, id, uint8(0), bytes("")));
        (uint256 valueAfter,, int24 tick) = _trancheValue(id, 0);
        if (valueAfter * FeraConstants.BPS < valueBefore * (FeraConstants.BPS - FeraConstants.MEME_RECENTER_MAX_SLIPPAGE_BPS))
        {
            revert ValueSlippage();
        }

        p.lastMemeRecenterTs = uint64(block.timestamp);
        p.depthBreachSince = 0;

        emit StrategyAction(
            PoolId.unwrap(id),
            uint8(FeraTypes.StrategyKind.Recenter),
            _floorTick(tick - FeraConstants.MEME_LADDER_CORE_TICKS, p.key.tickSpacing),
            _ceilTick(tick + FeraConstants.MEME_LADDER_CORE_TICKS, p.key.tickSpacing),
            0,
            justificationHash
        );
    }

    /// @dev INV-5″ depth metric: at-spot (in-range) ladder liquidity vs the liquidity the SAME
    ///      holdings would quote as a single v1 full-range position (L_fr = √(x·y)).
    function _depthBreached(PoolId id) internal view returns (bool) {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(id);
        PoolInfo storage p = pools[id];
        uint256 inRange;
        uint256 x;
        uint256 y;
        for (uint8 t; t < p.trancheCount; ++t) {
            TrancheState storage tr = tranches[id][t];
            uint256 n = tr.bands.length;
            for (uint256 i; i < n; ++i) {
                Band storage b = tr.bands[i];
                if (b.liquidity == 0) continue;
                if (b.tickLower <= tick && tick < b.tickUpper) inRange += b.liquidity;
                (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtPriceX96, b.tickLower, b.tickUpper, b.liquidity);
                x += a0;
                y += a1;
            }
        }
        uint256 lFullRange = Math.sqrt(x) * Math.sqrt(y); // √(x·y), overflow-free
        return inRange * FeraConstants.BPS < lFullRange * FeraConstants.MEME_RECENTER_DEPTH_FLOOR_MULT_BPS;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // RWA keeper strategies — all re-verify bounds ON-CHAIN (INV-6, PT-6, PT-7).
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraVault
    function recenter(PoolId id, int24 newTickLower, int24 newTickUpper, bytes32 justificationHash)
        external
        onlyKeeper
        nonReentrant
    {
        PoolInfo storage p = pools[id];
        uint256 oracle = _requireRecenterAllowed(id); // INV-6 gate (regime, open, hysteresis, TWAP)

        // PT-6 — ENFORCED (PARAMS.md#RWA_MIN_RECENTER_INTERVAL_SEC frozen at 14400s v2).
        if (p.lastRwaRecenterTs != 0 && block.timestamp - p.lastRwaRecenterTs < FeraConstants.RWA_MIN_RECENTER_INTERVAL_SEC)
        {
            revert RecenterTooSoon();
        }
        p.lastRwaRecenterTs = uint64(block.timestamp);

        _checkpoint(id, 0);
        poolManager.unlock(abi.encode(CB_REBALANCE_RWA, id, uint8(0), abi.encode(newTickLower, newTickUpper)));
        p.lastRecenterOracle = oracle;

        emit StrategyAction(
            PoolId.unwrap(id), uint8(FeraTypes.StrategyKind.Recenter), newTickLower, newTickUpper, oracle, justificationHash
        );
    }

    /// @inheritdoc IFeraVault
    function widen(PoolId id, int24 newTickLower, int24 newTickUpper, bytes32 justificationHash)
        external
        onlyKeeper
        nonReentrant
    {
        PoolInfo storage p = pools[id];
        if (!p.initialized) revert UnknownPool();
        if (p.regime != FeraTypes.Regime.RWA) revert NotRwa();
        if (_isMarketOpen(id)) revert MarketOpen(); // widen is an OFF-hours action

        _checkpoint(id, 0);
        poolManager.unlock(abi.encode(CB_REBALANCE_RWA, id, uint8(0), abi.encode(newTickLower, newTickUpper)));

        emit StrategyAction(
            PoolId.unwrap(id), uint8(FeraTypes.StrategyKind.Widen), newTickLower, newTickUpper, _readOracle(id), justificationHash
        );
    }

    /// @inheritdoc IFeraVault
    /// @dev PT-7: pull ≤ q of the CORE band into reserves (principal preserved for shareholders,
    ///      redeployed at the next recenter). q = 0.60 off-hours, 0.80 in a keeper-flagged event
    ///      session (fail-static: flag absent ⇒ 0.60). Anchor (tranche 1) is exempt by design.
    function partialWithdraw(PoolId id, uint128 liquidityToPull, bytes32 justificationHash)
        external
        onlyKeeper
        nonReentrant
    {
        PoolInfo storage p = pools[id];
        if (!p.initialized) revert UnknownPool();
        if (p.regime != FeraTypes.Regime.RWA) revert NotRwa();
        if (_isMarketOpen(id)) revert MarketOpen();

        TrancheState storage tr = tranches[id][0];
        uint256 maxFrac =
            p.eventWindow ? FeraConstants.RWA_EVENT_WITHDRAW_FRAC_BPS : FeraConstants.RWA_OFFHOURS_WITHDRAW_FRAC_BPS;
        if (uint256(liquidityToPull) * FeraConstants.BPS > uint256(tr.bands[0].liquidity) * maxFrac) {
            revert WithdrawFracExceeded();
        }

        _checkpoint(id, 0);
        poolManager.unlock(abi.encode(CB_PULL, id, uint8(0), abi.encode(uint256(liquidityToPull))));

        emit StrategyAction(
            PoolId.unwrap(id),
            uint8(FeraTypes.StrategyKind.PartialWithdraw),
            tr.bands[0].tickLower,
            tr.bands[0].tickUpper,
            _readOracle(id),
            justificationHash
        );
    }

    /// @inheritdoc IFeraVault
    /// @dev Fee income into the tranche's FIRST band, ticks unchanged (kind=4). Legal on MEME too
    ///      (fee income is INV-5″-deployable); principal is never sourced here.
    function compound(PoolId id, uint8 t, bytes32 justificationHash) external onlyKeeper nonReentrant knownTranche(id, t) {
        _checkpoint(id, t);
        TrancheState storage tr = tranches[id][t];
        (uint256 used0, uint256 used1) = abi.decode(
            poolManager.unlock(abi.encode(CB_ADD_TO_BAND, id, t, abi.encode(uint256(0), tr.pending0, tr.pending1))),
            (uint256, uint256)
        );
        tr.pending0 -= used0;
        tr.pending1 -= used1;

        emit StrategyAction(
            PoolId.unwrap(id),
            uint8(FeraTypes.StrategyKind.CompoundInPlace),
            tr.bands[0].tickLower,
            tr.bands[0].tickUpper,
            0,
            justificationHash
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // INV-6 gate — re-verify oracle + hysteresis + market-hours + TWAP entirely on-chain.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @dev Returns the fresh oracle price if an RWA recenter is permitted; reverts otherwise.
    function _requireRecenterAllowed(PoolId id) internal view returns (uint256 oracle) {
        PoolInfo storage p = pools[id];
        if (!p.initialized) revert UnknownPool();
        if (p.regime != FeraTypes.Regime.RWA) revert NotRwa(); // MEME uses recenterMeme (INV-5″)
        if (!_isMarketOpen(id)) revert MarketClosed(); // INV-6: market open

        oracle = _readOracle(id); // reverts OracleStale on stale/unset feed

        // INV-6: oracle must have moved past hysteresis since the last recenter.
        uint256 moveBps = _absDeviationBps(p.lastRecenterOracle, oracle);
        if (moveBps < FeraConstants.RWA_HYSTERESIS_BPS) revert HysteresisNotMet();

        // INV-6: pool TWAP must be within the sanity band of the oracle (anti-manipulation).
        uint256 twap = _poolTwapPrice(id, FeraConstants.RWA_TWAP_WINDOW);
        if (_absDeviationBps(twap, oracle) > FeraConstants.RWA_TWAP_SANITY_BPS) revert TwapOutOfBand();
    }

    /// @dev Read Chainlink feed with staleness guard. Returns price scaled to 1e18. Reverts if stale.
    function _readOracle(PoolId id) internal view returns (uint256) {
        address feed = pools[id].oracleFeed;
        if (feed == address(0)) revert OracleStale();
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > FeraConstants.ORACLE_STALENESS_MAX) revert OracleStale();
        uint8 dec = IAggregatorV3(feed).decimals(); // per-feed decimals — never assumed (D-9)
        return uint256(answer) * (10 ** (18 - dec));
    }

    /// @dev Market-hours check (INV-12 / §10 / SEC-3 #7). Combines, in fail-static order:
    ///        (1) keeper HOLIDAY flag — force-closes (a keeper can only ever CLOSE, never open);
    ///        (2) keeper market-hours flag — the redundant-keeper liveness signal (§10);
    ///        (3) an on-chain UTC weekly SCHEDULE bitmap — 168 bits, bit `h` = "open at hour-of-week
    ///            h", where hour-of-week 0 is 00:00 UTC Thursday (the unix-epoch weekday), i.e.
    ///            h = (block.timestamp / 3600) % 168. An UNSET calendar (bitmap == 0) defers wholly
    ///            to the keeper flag (back-compat + fail-static: a pool with no calendar still
    ///            operates on keeper hours). A SET calendar bounds the keeper: the market is open
    ///            ONLY when the schedule AND the keeper flag agree — the keeper can never hold the
    ///            market open outside the published on-chain calendar.
    ///      The keeper "only flips a flag within bounds" (§10) is now ENFORCED on-chain by (3).
    function _isMarketOpen(PoolId id) internal view returns (bool) {
        PoolInfo storage p = pools[id];
        if (p.holiday) return false; // (1) keeper holiday flag — force close
        if (!p.marketOpen) return false; // (2) keeper hours flag
        uint256 sched = p.scheduleBitmap;
        if (sched == 0) return true; // no calendar configured ⇒ keeper flag governs (back-compat)
        // slither-disable-next-line weak-prng — hour-of-week calendar index (modulo), not randomness.
        uint256 hourOfWeek = (block.timestamp / 3_600) % 168; // (3) on-chain UTC weekly calendar
        return (sched >> hourOfWeek) & 1 == 1;
    }

    /// @dev Pool TWAP price (1e18) over `window` seconds, from the hook's manipulation-resistant
    ///      cumulative-tick oracle (V2-2 / SEC-3 — replaces the inert spot scaffold). Falls back to
    ///      spot when the oracle has no elapsed history yet (fresh pool), which is conservative:
    ///      spot==TWAP ⇒ deviation 0 ⇒ the gate is open, never a false revert on a brand-new pool.
    function _poolTwapPrice(PoolId id, uint32 window) internal view returns (uint256) {
        (uint160 sqrtSpot,,,) = poolManager.getSlot0(id);
        (int24 twapTick, bool ready) = hook.consultTwapTick(id, window);
        uint160 sqrtPriceX96;
        if (ready) {
            // REC-9 FAIL-CLOSED: if the newest observation is older than the max-staleness bound the
            // pool is dormant and the "TWAP" is `_lastTick` extrapolated across an unbounded gap — an
            // untrustworthy near-spot value. Revert the strategy/deposit-gate path (this helper is only
            // ever reached from the deposit gate + recenter, NEVER a swap — INV-2) instead of trusting
            // it. A single (permissionless) swap refreshes the head and re-arms these paths.
            (uint32 ageSec, bool has) = hook.twapObservationAge(id);
            if (has && ageSec > FeraConstants.TWAP_MAX_STALENESS_SEC) revert TwapStale();
            sqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);
        } else {
            // No elapsed history yet (brand-new pool): fall back to spot. Conservative — spot==TWAP ⇒
            // deviation 0 ⇒ the gate is open, never a false revert on a pool that has no history to be
            // stale (nothing to manipulate against).
            sqrtPriceX96 = sqrtSpot;
        }
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        return FullMath.mulDiv(priceX96, 1e18, 1 << 96);
    }

    /// @dev |spot − TWAP(window)| in bps of the TWAP. Same-block price manipulation does not move
    ///      the TWAP (see FeraHook.consultTwapTick), so a flash push shows up here as a large
    ///      deviation and trips the deposit gate — the Gamma defence the scaffold could not provide.
    function _twapDeviationBps(PoolId id, uint32 window) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint256 spot = FullMath.mulDiv(
            FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), 1e18, 1 << 96
        );
        return _absDeviationBps(spot, _poolTwapPrice(id, window));
    }

    function _absDeviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) return type(uint256).max; // undefined baseline ⇒ treat as out-of-band
        uint256 diff = a > b ? a - b : b - a;
        return (diff * FeraConstants.BPS) / b;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // v4 unlock callback — the ONLY place liquidity is mutated (flash accounting). Every action
    // is scoped to ONE tranche's bands via the tranche-scoped salt (INV-15 / D-18).
    // ═══════════════════════════════════════════════════════════════════════════════════════

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyKeeper();
        (uint8 action, PoolId id, uint8 t, bytes memory payload) = abi.decode(data, (uint8, PoolId, uint8, bytes));

        if (action == CB_CHECKPOINT) return _cbCheckpoint(id, t);
        if (action == CB_FIRST_DEPOSIT) return _cbFirstDeposit(id, t, payload);
        if (action == CB_DEPOSIT) return _cbDeposit(id, t, payload);
        if (action == CB_WITHDRAW) return _cbWithdraw(id, t, payload);
        if (action == CB_ADD_TO_BAND) return _cbAddToBand(id, t, payload);
        if (action == CB_NEW_BAND) return _cbNewBand(id, t, payload);
        if (action == CB_RECENTER_MEME) return _cbRecenterMeme(id);
        if (action == CB_REBALANCE_RWA) return _cbRebalanceRwa(id, payload);
        return _cbPull(id, payload); // CB_PULL
    }

    /// @dev D-18: tranche-scoped position salt — identical (owner,ticks) in different tranches can
    ///      NEVER merge into one v4 position.
    function _salt(uint8 t) internal pure returns (bytes32) {
        return bytes32(uint256(t) + 1);
    }

    /// @dev Modify one band's liquidity and resolve the Vault's currency deltas (settle debts from
    ///      Vault balance, take credits to the Vault). Returns (received0, received1) for positive
    ///      deltas — for a poke these are exactly the fees realized (post-JIT-withholding).
    function _modifyBand(PoolId id, uint8 t, int24 lower, int24 upper, int256 liquidityDelta)
        internal
        returns (uint256 in0, uint256 in1)
    {
        PoolInfo storage p = pools[id];
        (BalanceDelta cd,) = poolManager.modifyLiquidity(
            p.key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: _salt(t)}),
            ""
        );
        in0 = _resolveDelta(p.key.currency0, cd.amount0());
        in1 = _resolveDelta(p.key.currency1, cd.amount1());
    }

    function _resolveDelta(Currency c, int128 amount) internal returns (uint256 received) {
        if (amount < 0) {
            c.settle(poolManager, address(this), uint256(uint128(-amount)), false);
        } else if (amount > 0) {
            c.take(poolManager, address(this), uint256(uint128(amount)), false);
            received = uint256(uint128(amount));
        }
    }

    function _cbCheckpoint(PoolId id, uint8 t) internal returns (bytes memory) {
        TrancheState storage tr = tranches[id][t];
        uint256 fee0;
        uint256 fee1;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            if (b.liquidity == 0) continue;
            (uint256 f0, uint256 f1) = _modifyBand(id, t, b.tickLower, b.tickUpper, 0);
            fee0 += f0;
            fee1 += f1;
        }
        return abi.encode(fee0, fee1);
    }

    function _cbFirstDeposit(PoolId id, uint8 t, bytes memory payload) internal returns (bytes memory) {
        (uint256 amount0, uint256 amount1) = abi.decode(payload, (uint256, uint256));
        TrancheState storage tr = tranches[id][t];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);

        uint256 sumDL;
        uint256 used0;
        uint256 used1;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(b.tickLower),
                TickMath.getSqrtPriceAtTick(b.tickUpper),
                (amount0 * b.weightBps) / FeraConstants.BPS,
                (amount1 * b.weightBps) / FeraConstants.BPS
            );
            if (dL == 0) continue;
            uint256 bal0Before = pools[id].key.currency0.balanceOfSelf();
            uint256 bal1Before = pools[id].key.currency1.balanceOfSelf();
            _modifyBand(id, t, b.tickLower, b.tickUpper, int256(uint256(dL)));
            used0 += bal0Before - pools[id].key.currency0.balanceOfSelf();
            used1 += bal1Before - pools[id].key.currency1.balanceOfSelf();
            b.liquidity += dL;
            sumDL += dL;
        }
        return abi.encode(sumDL, used0, used1);
    }

    function _cbDeposit(PoolId id, uint8 t, bytes memory payload) internal returns (bytes memory) {
        (uint256 amount0, uint256 amount1) = abi.decode(payload, (uint256, uint256));
        TrancheState storage tr = tranches[id][t];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);

        // Ratio-match: replicate the tranche's CURRENT composition. need = amounts for f = 1.
        uint256 need0;
        uint256 need1;
        uint256 sumLBefore;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            sumLBefore += b.liquidity;
            (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtPriceX96, b.tickLower, b.tickUpper, b.liquidity);
            need0 += a0;
            need1 += a1;
        }
        require(sumLBefore != 0, "empty");

        // f (WAD) = the largest uniform fraction of the current book this deposit can fund.
        uint256 f = type(uint256).max;
        if (need0 != 0) f = FullMath.mulDiv(amount0, WAD, need0);
        if (need1 != 0) {
            uint256 f1 = FullMath.mulDiv(amount1, WAD, need1);
            if (f1 < f) f = f1;
        }
        require(f != type(uint256).max && f != 0, "ratio");

        uint256 sumDL;
        uint256 used0;
        uint256 used1;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            // REC-10 robustness: fund each band with fraction `f` of ITS OWN current token amounts and
            // derive the liquidity via getLiquidityForAmounts, which rounds the LIQUIDITY down so the v4
            // mint can never require more than the allocated tokens. Σ allocations = Σfloor(a_j·f/WAD) ≤
            // f·need_j/WAD ≤ amount_j, so total `used` ≤ `amount` even when the tranche has NO reserve to
            // cover a v4 mint round-up — the pre-existing large-deposit revert (`used > amount`, insolvent
            // settle) when reserve==0. The old `dL = floor(b.liquidity·f/WAD)` used a floored `need`, so
            // `f` over-estimated and v4's round-up charge could exceed `amount`. Ratio-matching is
            // preserved: every band scales by the same `f` (identical to the old intent, minus dust).
            (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtPriceX96, b.tickLower, b.tickUpper, b.liquidity);
            uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(b.tickLower),
                TickMath.getSqrtPriceAtTick(b.tickUpper),
                FullMath.mulDiv(a0, f, WAD),
                FullMath.mulDiv(a1, f, WAD)
            );
            if (dL == 0) continue;
            uint256 bal0Before = pools[id].key.currency0.balanceOfSelf();
            uint256 bal1Before = pools[id].key.currency1.balanceOfSelf();
            _modifyBand(id, t, b.tickLower, b.tickUpper, int256(uint256(dL)));
            used0 += bal0Before - pools[id].key.currency0.balanceOfSelf();
            used1 += bal1Before - pools[id].key.currency1.balanceOfSelf();
            b.liquidity += dL;
            sumDL += dL;
        }
        return abi.encode(sumDL, sumLBefore, used0, used1);
    }

    function _cbWithdraw(PoolId id, uint8 t, bytes memory payload) internal returns (bytes memory) {
        (uint256 shares, uint256 totalShares, address to) = abi.decode(payload, (uint256, uint256, address));
        TrancheState storage tr = tranches[id][t];
        PoolInfo storage p = pools[id];

        uint256 out0;
        uint256 out1;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            uint128 dL = uint128(FullMath.mulDiv(b.liquidity, shares, totalShares)); // floor — R-17
            if (dL == 0) continue;
            (uint256 o0, uint256 o1) = _modifyBand(id, t, b.tickLower, b.tickUpper, -int256(uint256(dL)));
            out0 += o0;
            out1 += o1;
            b.liquidity -= dL;
        }
        if (out0 != 0) IERC20(Currency.unwrap(p.key.currency0)).safeTransfer(to, out0);
        if (out1 != 0) IERC20(Currency.unwrap(p.key.currency1)).safeTransfer(to, out1);
        return abi.encode(out0, out1);
    }

    function _cbAddToBand(PoolId id, uint8 t, bytes memory payload) internal returns (bytes memory) {
        (uint256 idx, uint256 amount0, uint256 amount1) = abi.decode(payload, (uint256, uint256, uint256));
        TrancheState storage tr = tranches[id][t];
        Band storage b = tr.bands[idx];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);

        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(b.tickLower), TickMath.getSqrtPriceAtTick(b.tickUpper), amount0, amount1
        );
        if (dL == 0) return abi.encode(uint256(0), uint256(0));

        uint256 bal0Before = pools[id].key.currency0.balanceOfSelf();
        uint256 bal1Before = pools[id].key.currency1.balanceOfSelf();
        _modifyBand(id, t, b.tickLower, b.tickUpper, int256(uint256(dL)));
        b.liquidity += dL;
        return abi.encode(
            bal0Before - pools[id].key.currency0.balanceOfSelf(), bal1Before - pools[id].key.currency1.balanceOfSelf()
        );
    }

    function _cbNewBand(PoolId id, uint8 t, bytes memory payload) internal returns (bytes memory) {
        (int24 lower, int24 upper, uint256 amount0, uint256 amount1) =
            abi.decode(payload, (int24, int24, uint256, uint256));
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);

        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
        if (dL == 0) return abi.encode(uint128(0), uint256(0), uint256(0));

        uint256 bal0Before = pools[id].key.currency0.balanceOfSelf();
        uint256 bal1Before = pools[id].key.currency1.balanceOfSelf();
        _modifyBand(id, t, lower, upper, int256(uint256(dL)));
        return abi.encode(
            dL, bal0Before - pools[id].key.currency0.balanceOfSelf(), bal1Before - pools[id].key.currency1.balanceOfSelf()
        );
    }

    /// @dev INV-5″ execution: close ONLY the principal bands, re-mint the 30/40/30 ladder centered
    ///      at current spot from realized amounts + reserves. Fee bands are untouched. No swap.
    function _cbRecenterMeme(PoolId id) internal returns (bytes memory) {
        TrancheState storage tr = tranches[id][0];
        PoolInfo storage p = pools[id];

        // 1) Close principal bands (collect realized principal into the Vault).
        uint256 got0;
        uint256 got1;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            if (!b.isPrincipal || b.liquidity == 0) continue;
            (uint256 o0, uint256 o1) = _modifyBand(id, 0, b.tickLower, b.tickUpper, -int256(uint256(b.liquidity)));
            got0 += o0;
            got1 += o1;
            b.liquidity = 0;
        }
        uint256 total0 = got0 + tr.reserve0;
        uint256 total1 = got1 + tr.reserve1;
        tr.reserve0 = 0;
        tr.reserve1 = 0;

        // 2) Re-anchor principal band ticks at spot and re-mint at ladder weights.
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(id);
        int24 spacing = p.key.tickSpacing;
        uint256 used0;
        uint256 used1;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            if (!b.isPrincipal) continue;
            bool isTail =
                b.tickLower == TickMath.minUsableTick(spacing) && b.tickUpper == TickMath.maxUsableTick(spacing);
            if (!isTail) {
                // Core / Mid bands re-center; the full-range tail keeps its ticks by construction.
                // Mid is uniquely weighted (4000); core (3000) is discriminated from the tail above.
                int24 half = b.weightBps == uint16(FeraConstants.MEME_LADDER_MID_WEIGHT_BPS)
                    ? FeraConstants.MEME_LADDER_MID_TICKS
                    : FeraConstants.MEME_LADDER_CORE_TICKS;
                (b.tickLower, b.tickUpper) = _bandAround(tick, half, spacing);
            }
            uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(b.tickLower),
                TickMath.getSqrtPriceAtTick(b.tickUpper),
                (total0 * b.weightBps) / FeraConstants.BPS,
                (total1 * b.weightBps) / FeraConstants.BPS
            );
            if (dL == 0) continue;
            uint256 bal0Before = p.key.currency0.balanceOfSelf();
            uint256 bal1Before = p.key.currency1.balanceOfSelf();
            _modifyBand(id, 0, b.tickLower, b.tickUpper, int256(uint256(dL)));
            used0 += bal0Before - p.key.currency0.balanceOfSelf();
            used1 += bal1Before - p.key.currency1.balanceOfSelf();
            b.liquidity = dL;
        }

        // 3) Whatever could not be re-banded (single-sided remainder — we do NOT swap) stays
        //    principal-class reserve, folded in at the next recenter/withdraw.
        tr.reserve0 = total0 - used0;
        tr.reserve1 = total1 - used1;
        return "";
    }

    function _cbRebalanceRwa(PoolId id, bytes memory payload) internal returns (bytes memory) {
        (int24 newLower, int24 newUpper) = abi.decode(payload, (int24, int24));
        TrancheState storage tr = tranches[id][0];
        Band storage b = tr.bands[0];

        uint256 got0;
        uint256 got1;
        if (b.liquidity != 0) {
            (got0, got1) = _modifyBand(id, 0, b.tickLower, b.tickUpper, -int256(uint256(b.liquidity)));
            b.liquidity = 0;
        }
        uint256 total0 = got0 + tr.reserve0;
        uint256 total1 = got1 + tr.reserve1;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(newLower), TickMath.getSqrtPriceAtTick(newUpper), total0, total1
        );
        b.tickLower = newLower;
        b.tickUpper = newUpper;
        uint256 used0;
        uint256 used1;
        if (dL != 0) {
            uint256 bal0Before = pools[id].key.currency0.balanceOfSelf();
            uint256 bal1Before = pools[id].key.currency1.balanceOfSelf();
            _modifyBand(id, 0, newLower, newUpper, int256(uint256(dL)));
            used0 = bal0Before - pools[id].key.currency0.balanceOfSelf();
            used1 = bal1Before - pools[id].key.currency1.balanceOfSelf();
            b.liquidity = dL;
        }
        tr.reserve0 = total0 - used0;
        tr.reserve1 = total1 - used1;
        return "";
    }

    function _cbPull(PoolId id, bytes memory payload) internal returns (bytes memory) {
        uint256 dL = abi.decode(payload, (uint256));
        TrancheState storage tr = tranches[id][0];
        Band storage b = tr.bands[0];
        (uint256 o0, uint256 o1) = _modifyBand(id, 0, b.tickLower, b.tickUpper, -int256(dL));
        b.liquidity -= uint128(dL);
        tr.reserve0 += o0;
        tr.reserve1 += o1;
        return "";
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Valuation / tick helpers
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @dev Tranche value in token1 terms at spot (bands + pending + reserves), plus spot context.
    function _trancheValue(PoolId id, uint8 t) internal view returns (uint256 v, uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(id);
        TrancheState storage tr = tranches[id][t];
        uint256 x = tr.pending0 + tr.reserve0;
        uint256 y = tr.pending1 + tr.reserve1;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage b = tr.bands[i];
            if (b.liquidity == 0) continue;
            (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtPriceX96, b.tickLower, b.tickUpper, b.liquidity);
            x += a0;
            y += a1;
        }
        v = _valueInToken1(sqrtPriceX96, x, y);
    }

    function _valueInToken1(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        return FullMath.mulDiv(amount0, priceX96, 1 << 96) + amount1;
    }

    /// @dev Token amounts a position of `liquidity` on [lower,upper] holds at `sqrtPriceX96`.
    function _amountsForLiquidity(uint160 sqrtPriceX96, int24 lower, int24 upper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        if (sqrtPriceX96 <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtPriceX96 >= sqrtB) {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liquidity, false);
        }
    }

    function _bandAround(int24 center, int24 half, int24 spacing) internal pure returns (int24 lower, int24 upper) {
        lower = _floorTick(center - half, spacing);
        upper = _ceilTick(center + half, spacing);
        int24 min = TickMath.minUsableTick(spacing);
        int24 max = TickMath.maxUsableTick(spacing);
        if (lower < min) lower = min;
        if (upper > max) upper = max;
    }

    function _fullRange(int24 spacing) internal pure returns (int24 lower, int24 upper) {
        return (TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing));
    }

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        // slither-disable-next-line weak-prng — tick-spacing alignment (modulo), not randomness.
        int24 r = tick % spacing;
        if (r < 0) r += spacing;
        return tick - r;
    }

    function _ceilTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 fl = _floorTick(tick, spacing);
        return fl == tick ? tick : fl + spacing;
    }

    function _pushBand(TrancheState storage tr, int24 lower, int24 upper, bool principal, uint16 weightBps) internal {
        tr.bands.push(Band({tickLower: lower, tickUpper: upper, liquidity: 0, isPrincipal: principal, weightBps: weightBps}));
    }

    function _refund(Currency c, address to, uint256 amount) internal {
        if (amount != 0) IERC20(Currency.unwrap(c)).safeTransfer(to, amount);
    }

    function _cloneShare(PoolId id, string calldata name_, string calldata symbol_, uint8 t) internal returns (address share) {
        share = Clones.clone(shareImplementation);
        IFeraShare(share).initialize(
            address(this),
            PoolId.unwrap(id),
            t == 0 ? string.concat(name_, " Core") : string.concat(name_, " Anchor"),
            t == 0 ? string.concat(symbol_, "-C") : string.concat(symbol_, "-A")
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Admin — deposit pause ONLY (INV-11); launchpad class gated off (v1); bounded gate setter
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Pause deposits for a pool. Withdrawals and swaps are NEVER affected (INV-11).
    function pauseDeposits(PoolId id) external onlyOwner {
        pools[id].paused = true;
    }

    /// @notice Unpause deposits.
    function unpauseDeposits(PoolId id) external onlyOwner {
        pools[id].paused = false;
    }

    /// @notice Set the deposit TWAP gate — timelocked owner, CLAMPED to the immutable [50,500]bp
    ///         legal range (PARAMS.md#DEPOSIT_TWAP_GATE_BPS). The Gamma exploit was exactly an
    ///         unbounded version of this parameter; the bounds live here, in code, forever.
    function setDepositTwapGate(uint256 gateBps) external onlyOwner {
        if (gateBps < FeraConstants.DEPOSIT_TWAP_GATE_MIN_BPS || gateBps > FeraConstants.DEPOSIT_TWAP_GATE_MAX_BPS) {
            revert GateOutOfBounds();
        }
        depositTwapGateBps = gateBps;
    }

    /// @notice RWA market-hours keeper flag (bounded). Mirrored onto the hook for the fee overlay.
    function setMarketOpen(PoolId id, bool open) external onlyKeeper {
        pools[id].marketOpen = open;
        hook.setMarketOpen(id, open);
    }

    /// @notice Keeper flags a scheduled-event session (earnings before next open — D-M11).
    ///         Bounded: it ONLY raises the partial-withdraw cap 0.60 → 0.80. Fail-static.
    function setEventWindow(PoolId id, bool on) external onlyKeeper {
        pools[id].eventWindow = on;
    }

    /// @notice Keeper holiday flag (§10) — force-closes an RWA market regardless of the calendar or
    ///         the hours flag. Fail-static: a keeper can only CLOSE the market with this, never open.
    function setHoliday(PoolId id, bool on) external onlyKeeper {
        pools[id].holiday = on;
        hook.setHoliday(id, on); // mirror onto the hook so the fee overlay force-closes too (§2.1)
    }

    /// @notice Set the on-chain UTC weekly trading calendar (168-bit hour-of-week bitmap; see
    ///         `_isMarketOpen`). Timelocked owner — this is the immutable-within-timelock BOUND the
    ///         keeper's hours flag operates inside (SEC-3 #7). `0` disables the calendar (keeper
    ///         flag governs). Withdrawals/swaps are never gated by this (INV-11/INV-2).
    function setSchedule(PoolId id, uint256 weeklyBitmap) external onlyOwner {
        if (!pools[id].initialized) revert UnknownPool();
        pools[id].scheduleBitmap = weeklyBitmap;
        hook.setSchedule(id, weeklyBitmap); // mirror onto the hook so the fee overlay uses the calendar
    }

    /// @notice Enable the non-redeemable launchpad share class — reverts in v1 (gated off).
    function enableLaunchpad(PoolId) external view onlyOwner {
        revert LaunchpadDisabled(); // present in the type system; disabled in v1 (D-1 / §4)
    }

    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    // ── IFeraVault views ───────────────────────────────────────────────────────────────────
    function shareToken(PoolId id, uint8 t) external view returns (address) {
        return tranches[id][t].share;
    }

    function regimeOf(PoolId id) external view returns (FeraTypes.Regime) {
        return pools[id].regime;
    }

    /// @notice F-12: read-only mirror of the on-chain market-hours gate (`_isMarketOpen`) so the
    ///         Backend marketHours/rwaStrategy keepers, `ops/reconcile`, and the API can query
    ///         whether the RWA strategy paths (recenter/widen/partialWithdraw) are open WITHOUT
    ///         reproducing the holiday/keeper-flag/schedule-bitmap logic off-chain. Pure view.
    function isMarketOpen(PoolId id) external view returns (bool) {
        return _isMarketOpen(id);
    }

    /// @notice F-12: whether a keeper-flagged scheduled-event session is active (D-M11) — the flag
    ///         that raises the off-hours partial-withdraw cap 0.60 → 0.80. Pure view.
    function isEventWindow(PoolId id) external view returns (bool) {
        return pools[id].eventWindow;
    }

    function depositsPaused(PoolId id) external view returns (bool) {
        return pools[id].paused;
    }

    function trancheCount(PoolId id) external view returns (uint8) {
        return pools[id].trancheCount;
    }

    function bandCount(PoolId id, uint8 t) external view returns (uint256) {
        return tranches[id][t].bands.length;
    }

    function bandAt(PoolId id, uint8 t, uint256 index)
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, bool isPrincipal)
    {
        Band storage b = tranches[id][t].bands[index];
        return (b.tickLower, b.tickUpper, b.liquidity, b.isPrincipal);
    }

    function pendingFees(PoolId id, uint8 t) external view returns (uint256 pending0, uint256 pending1) {
        TrancheState storage tr = tranches[id][t];
        return (tr.pending0, tr.pending1);
    }

    function depthBreachSince(PoolId id) external view returns (uint64) {
        return pools[id].depthBreachSince;
    }
}
