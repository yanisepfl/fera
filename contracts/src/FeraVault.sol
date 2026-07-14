// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IFeraVault} from "./interfaces/IFeraVault.sol";
import {IFeraShare} from "./interfaces/IFeraShare.sol";
import {IFeraHook} from "./interfaces/IFeraHook.sol";
import {IRevenueDistributor} from "./interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "./interfaces/IAnchorStaking.sol";
import {IRebalanceVenue} from "./interfaces/IRebalanceVenue.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {FeraTypes} from "./libraries/FeraTypes.sol";
import {FeraConstants} from "./libraries/FeraConstants.sol";
import {FeeLogic} from "./libraries/FeeLogic.sol";

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
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeraVault (v3 — base+limit+idle is the ONLY strategy; contracts/VAULT_STRATEGY_V3.md)
/// @notice The managed-liquidity layer of FERA. Per pool the Vault runs the industry-standard
///         BASE + LIMIT + IDLE shape (Arrakis v2 / Gamma / Charm / Steer) across exactly 2 risk
///         TRANCHES (Steady, Active), each an independent per-pool ERC-20 share class over a
///         DISJOINT band set (INV-15). Under open liquidity (D-11) anyone may LP directly; the
///         Vault's exclusive carrot is emissions (INV-14) — enforced off-chain from these events.
///         The legacy Core/Mid/Tail band-ladder + drip + INV-5″ guarded-recenter surface is REMOVED
///         (not stubbed) — nothing was ever deployed, so there is no compatibility obligation.
/// @dev    INVARIANT MAP:
///          - INV-3  : `collectFees`/`_checkpoint` skim EXACTLY 10% of collected fees per tranche;
///            principal never enters the fee path.
///          - INV-11 : deposits pausable + TWAP-gated (revertable); withdrawals NEVER pausable —
///            only the depositor's own 1h cooldown (Veda share-lock, PARAMS §D2) applies.
///          - INV-15 : every band belongs to exactly one tranche; all callback actions are
///            tranche-scoped; v4 position SALTS are tranche-scoped (D-18) so positions can never
///            merge across tranches; fees checkpoint into the owning tranche only.
///          - D-18   : fee-checkpoint-before-mint — every deposit/withdraw first pokes the
///            tranche's bands (v4 auto-collects on modifyLiquidity, so mints would otherwise
///            misprice); the JIT guard (INV-1″) applies to the Vault exactly like any other LP.
///          - v3 §6  : `rebalanceLimit`/`rebalanceBase`/`selfSwap`/`rebalanceViaVenue` are
///            PERMISSIONLESS (Uniswap-v3-collect / Aave-liquidation pattern) — every safety bound
///            (interval, dwell, TWAP-confirmation, execution-slippage, IL-cap) is re-verified
///            ON-CHAIN regardless of caller. `pokeOutOfRange` stays permissionless + IDEMPOTENT.
///          - v3.3 §11: `createBaseLimitPool` is ALSO now PERMISSIONLESS (no DAO — a team-run
///            protocol; "team"/"admin" everywhere, never "governance"). This does NOT weaken INV-1″
///            (open liquidity) or INV-14 (emissions only to vault shares) — it only removes the
///            caller-gate on CREATION and adds two narrower team-curated levers in its place:
///            `allowedQuoteAssets` (both regimes — the quote side must be team-allowlisted, closing
///            the fake/self-referential-quote-asset risk to the §9 fee-routing self-swap) and
///            `approvedRwaFeeds` (RWA only — the oracle feed must be team-verified, closing the
///            fake-oracle risk; MEME has no oracle dependency, so no registry applies to it). A
///            THIRD, fully independent team-only lever, `emissionsEligible` (default FALSE per
///            pool), gates ONLY whether the off-chain esFERA emissions pipeline attributes emissions
///            to a pool — it has ZERO on-chain effect on fee generation/collection/routing: a
///            non-eligible pool still fully participates in `collectFees`/INV-3/the §9 unified
///            fee-routing split, exactly like any eligible pool.
contract FeraVault is IFeraVault, IUnlockCallback, Ownable, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IFeraHook public immutable hook;
    IRevenueDistributor public immutable revenueDistributor;
    /// @notice v3.1 unified fee-routing (contracts/VAULT_STRATEGY_V3.md §9): the AnchorStaking
    ///         instance consulted for (a) whether a pool's native/quote tokens are already on the
    ///         reward-token allowlist (decides the no-swap vs bounded-self-swap path) and (b)
    ///         whether `totalStaked() == 0` (decides whether the stakers' 50% leg reroutes to
    ///         treasury). MAY be `address(0)` (legacy/pre-this-stage deployments, and most existing
    ///         test fixtures that never wired a real AnchorStaking) — the unified-routing logic
    ///         then degrades to the pre-existing behavior (both sides routed directly via
    ///         RevenueDistributor, no swap, no reroute) rather than guessing. Immutable: no
    ///         governance action can silently redirect where perf fees are introspected from.
    IAnchorStaking public immutable anchorStaking;
    address public immutable shareImplementation; // FeraShare impl for EIP-1167 cloning
    address public keeper;

    /// @dev Locked forever on first deposit (per tranche) to defuse share-inflation (R-12).
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant WAD = 1e18;

    /// @notice PARAMS.md#DEPOSIT_TWAP_GATE_BPS — timelocked-owner-settable WITHIN the immutable
    ///         [50,500]bp legal range hardcoded in `setDepositTwapGate` (the Gamma lesson).
    uint256 public depositTwapGateBps = FeraConstants.DEPOSIT_TWAP_GATE_DEFAULT_BPS;

    /// @notice v3: governance-set clamp band [minBps,maxBps] (bps of 1x) for the vol-adaptive
    ///         band-width multiplier (§2), timelocked-owner-settable WITHIN the immutable
    ///         [VOL_WIDTH_MULT_MIN_LEGAL_BPS, VOL_WIDTH_MULT_MAX_LEGAL_BPS] legal range.
    uint256 public volWidthMultMinBps = FeraConstants.VOL_WIDTH_MULT_MIN_BPS_DEFAULT;
    uint256 public volWidthMultMaxBps = FeraConstants.VOL_WIDTH_MULT_MAX_BPS_DEFAULT;

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
        /// @notice v3.1 unified fee-routing config (contracts/VAULT_STRATEGY_V3.md §9): which side
        ///         of the pair is the liquid QUOTE asset (WETH/USDG-like) vs the pool's own NATIVE/
        ///         project token (memecoin, stock token). Set ONCE at `createBaseLimitPool`,
        ///         immutable thereafter — a pool's token roles never change post-creation.
        bool quoteIsToken0;
        uint256 scheduleBitmap; // on-chain UTC weekly calendar (168 bits = hour-of-week; see _isMarketOpen)
    }

    mapping(PoolId => PoolInfo) internal pools;
    mapping(PoolId => mapping(uint256 => TrancheState)) internal tranches;
    /// @dev Per-(pool,tranche) tier config, OOR dwell clock, rebalance min-interval clock, and the
    ///      governance venue allowlist.
    mapping(PoolId => mapping(uint256 => TierConfig)) internal tierConfig;
    mapping(PoolId => mapping(uint256 => uint64)) internal oorSince; // base out-of-range since (0 = in range)
    mapping(PoolId => mapping(uint256 => uint64)) internal lastRebalanceTs; // R-15 min-interval clock
    mapping(address => bool) public rebalanceVenueAllowed;
    /// @dev PARAMS.md#DEPOSIT_COOLDOWN_SEC: per-(pool,tranche,user) last deposit; blocks only that
    ///      user's own redemption for 1h (narrow — no INV-11 tension).
    mapping(PoolId => mapping(uint256 => mapping(address => uint64))) public lastDepositTs;

    /// @notice v3.3 permissionless pool creation (contracts/VAULT_STRATEGY_V3.md §11): team-set
    ///         allowlist of acceptable QUOTE-side assets (WETH/USDG-like). `createBaseLimitPool` is
    ///         now callable by ANY address, but the pool's designated quote token (per
    ///         `quoteIsToken0`) MUST be on this allowlist — for BOTH regimes, since the unified
    ///         fee-routing self-swap (§9) trusts the quote side to be reasonably liquid regardless
    ///         of whether the pool is MEME or RWA. onlyOwner-gated (`setAllowedQuoteAsset`) — a
    ///         trust/curation decision, not a mechanical/safety-bounded action.
    mapping(address => bool) public allowedQuoteAssets;

    /// @notice v3.3 (item 2): team-curated registry of Chainlink feeds the team has verified as
    ///         legitimate. An RWA pool's `oracleFeed` MUST be on this registry — MEME pool creation
    ///         never consults it (no oracle dependency, no fake-oracle risk to curate against).
    ///         onlyOwner-gated (`approveRwaFeed`/`revokeRwaFeed`).
    mapping(address => bool) public approvedRwaFeeds;

    /// @notice v3.3 (item 3): per-pool esFERA emissions-eligibility flag, settable ONLY by the team
    ///         (`setEmissionsEligible`). Defaults FALSE for every pool (permissionlessly-created or
    ///         not) until the team opts it in. IMPORTANT: this flag gates ONLY off-chain esFERA
    ///         emission attribution (see `setEmissionsEligible`'s NatSpec) — it has NO on-chain
    ///         effect on fee generation/collection/routing (INV-3, §9 unified fee-routing); a
    ///         non-eligible pool still fully participates in fee generation and the perf-fee
    ///         staker/treasury/ops split exactly like any other pool.
    mapping(PoolId => bool) public emissionsEligible;

    // Callback action tags (internal encoding only — never externally exposed).
    uint8 internal constant CB_CHECKPOINT = 0; // poke bands, realize fees to the Vault
    uint8 internal constant CB_FIRST_DEPOSIT = 1; // weight-split initial mint
    uint8 internal constant CB_DEPOSIT = 2; // pro-rata (ratio-matched) add
    uint8 internal constant CB_WITHDRAW = 3; // pro-rata remove, pay user
    uint8 internal constant CB_SKIM_IDLE = 4; // pull IDLE fraction of base into reserve
    uint8 internal constant CB_REBALANCE_LIMIT = 5; // collect + redeploy the skewed limit (swap-free)
    uint8 internal constant CB_REBALANCE_BASE = 6; // guarded base recenter (+ optional bounded self-swap)
    uint8 internal constant CB_SELF_SWAP = 7; // standalone bounded self-swap against own pool
    uint8 internal constant CB_WITHDRAW_SINGLE = 8; // pro-rata remove + self-swap to one token
    uint8 internal constant CB_ROUTE_FEE_SWAP = 9; // v3.1: bounded self-swap of a native-side perf fee into the pool's quote asset (unified fee-routing, §9)

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
        IAnchorStaking anchorStaking_,
        address shareImplementation_,
        address keeper_,
        address timelockOwner
    ) Ownable(timelockOwner) {
        if (shareImplementation_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        // NOTE: anchorStaking_ MAY be address(0) by design (see the field's NatSpec) — it is not
        // subject to the ZeroAddress guard above.
        poolManager = poolManager_;
        hook = hook_;
        revenueDistributor = revenueDistributor_;
        anchorStaking = anchorStaking_;
        shareImplementation = shareImplementation_;
        keeper = keeper_;
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
            // First deposit: mint the band set at its frozen weights; lock MINIMUM_LIQUIDITY (R-12).
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

    /// @dev Poke the tranche's bands (realizing fees), skim EXACTLY 10%, retain 90% as pending LP
    ///      income. INV-15: only tranche `t`'s bands are poked; only its pending is credited.
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

        _routeUnifiedPerfFee(id, t, perfFee0, perfFee1);

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

    /// @dev v3.1 unified fee-routing (contracts/VAULT_STRATEGY_V3.md §9). Determines the pool's
    ///      NATIVE (project token) vs QUOTE (liquid) side from the immutable per-pool config set at
    ///      `createBaseLimitPool` (`PoolInfo.quoteIsToken0`), then:
    ///       - if BOTH sides are already on AnchorStaking's reward-token allowlist (e.g. a WETH/USDG
    ///         pool), skip the swap entirely and route both amounts DIRECTLY (gas-cheapest path —
    ///         byte-identical to the pre-unified-routing behavior).
    ///       - else, bound-self-swap the NATIVE-side perf fee into the pool's quote asset — the
    ///         EXACT SAME primitive (`_doSelfSwap`) rebalancing uses: same PoolManager.swap-in-unlock
    ///         mechanism, same TWAP-derived minOut, same MAX_REBALANCE_SLIPPAGE_BPS bound — spending
    ///         ONLY `nativePerfFee` (the amount actually collected from THIS pool/tranche checkpoint;
    ///         never inflated, never another pool's liquidity or the vault's other reserves). If the
    ///         swap would exceed the bound (thin liquidity / a hostile pool) OR reverts for ANY other
    ///         reason (a hostile/reverting/fee-on-transfer native token), the attempt is caught and
    ///         collectFees falls back SILENTLY and AUTOMATICALLY to forwarding the native amount
    ///         IN-KIND, entirely to treasury (never split 50/25/25 — it is illiquid/unswappable dust;
    ///         treasury can hold/decide later). collectFees itself NEVER reverts because of this.
    ///      If `anchorStaking` is not wired (address(0) — legacy/pre-this-stage deployments and most
    ///      pre-existing test fixtures), this degrades to the exact pre-existing behavior: both sides
    ///      routed directly, no swap, no allowlist/zero-staked introspection attempted.
    function _routeUnifiedPerfFee(PoolId id, uint8 t, uint256 perfFee0, uint256 perfFee1) internal {
        if (perfFee0 == 0 && perfFee1 == 0) return;
        PoolInfo storage p = pools[id];

        if (address(anchorStaking) == address(0)) {
            _routePerfFee(p.key.currency0, perfFee0);
            _routePerfFee(p.key.currency1, perfFee1);
            return;
        }

        bool isQuoteToken0 = p.quoteIsToken0;
        Currency quoteCurrency = isQuoteToken0 ? p.key.currency0 : p.key.currency1;
        Currency nativeCurrency = isQuoteToken0 ? p.key.currency1 : p.key.currency0;
        uint256 quotePerfFee = isQuoteToken0 ? perfFee0 : perfFee1;
        uint256 nativePerfFee = isQuoteToken0 ? perfFee1 : perfFee0;

        bool nativeAllowed = anchorStaking.isRewardToken(Currency.unwrap(nativeCurrency));
        bool quoteAllowed = anchorStaking.isRewardToken(Currency.unwrap(quoteCurrency));

        if (nativeAllowed && quoteAllowed) {
            // Gas-cheapest path: both sides already liquid reward tokens — split directly, no swap,
            // no extra poolManager.unlock() round trip.
            _routePerfFee(p.key.currency0, perfFee0);
            _routePerfFee(p.key.currency1, perfFee1);
            return;
        }

        if (nativePerfFee != 0) {
            bool zeroForOne = !isQuoteToken0; // native==token0 (quote==token1) sells token0 for token1
            try poolManager.unlock(
                abi.encode(CB_ROUTE_FEE_SWAP, id, t, abi.encode(zeroForOne, nativePerfFee))
            ) returns (bytes memory ret) {
                uint256 swappedOut = abi.decode(ret, (uint256));
                quotePerfFee += swappedOut;
                emit PerfFeeSwapped(
                    PoolId.unwrap(id), t, Currency.unwrap(nativeCurrency), nativePerfFee, Currency.unwrap(quoteCurrency), swappedOut
                );
            } catch {
                // FAIL-STATIC fallback (never reverts collectFees): forward the native perf fee
                // in-kind, ENTIRELY to treasury. Covers both (a) the bounded swap legitimately
                // exceeding MAX_REBALANCE_SLIPPAGE_BPS (thin/hostile pool) and (b) ANY other revert
                // inside the swap attempt (e.g. a reverting/hostile native token rejecting the
                // settle-side transfer) — either way, the fee is never lost and collection never
                // blocks.
                _forwardInKindToTreasury(id, t, Currency.unwrap(nativeCurrency), nativePerfFee);
            }
        }

        _routePerfFee(quoteCurrency, quotePerfFee);
    }

    /// @dev Route a single currency's perf-fee amount through RevenueDistributor's standard
    ///      50/25/25 split. v3.1 NO-STAKER ROUTING: if AnchorStaking reports zero total staked at
    ///      this moment, the stakers' 50% leg is folded into treasury instead (`notifyRevenueNoStakers`)
    ///      rather than crediting a pending balance nobody can yet claim pro-rata to real staked
    ///      time — the whoever-stakes-first windfall the decided spec calls out. Once totalStaked is
    ///      nonzero again, subsequent checkpoints route to stakers normally. A simple branch at the
    ///      call site, not a structural change to RevenueDistributor's existing `notifyRevenue`.
    function _routePerfFee(Currency c, uint256 amount) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(c);
        IERC20(token).safeTransfer(address(revenueDistributor), amount);
        if (address(anchorStaking) != address(0) && anchorStaking.totalStaked() == 0) {
            revenueDistributor.notifyRevenueNoStakers(token, amount);
        } else {
            revenueDistributor.notifyRevenue(token, amount);
        }
    }

    /// @dev FAIL-STATIC forward: a hostile/reverting/fee-on-transfer native token must NEVER brick
    ///      collectFees. Uses a raw low-level call (NOT SafeERC20, which itself reverts on a false
    ///      return or a revert) and silently tolerates failure either way — worst case the dust
    ///      remains in the Vault's own balance (still physically present, recoverable by a future
    ///      governance action), but collection can never be blocked by an adversarial project token.
    function _forwardInKindToTreasury(PoolId id, uint8 t, address token, uint256 amount) internal {
        if (amount == 0) return;
        address treasury_ = revenueDistributor.treasury();
        (bool ok,) = token.call(abi.encodeCall(IERC20.transfer, (treasury_, amount)));
        emit PerfFeeInKindFallback(PoolId.unwrap(id), t, token, amount, ok);
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
    // BASE + LIMIT + IDLE — the ONLY strategy (contracts/VAULT_STRATEGY_V3.md). v3: `rebalanceLimit`,
    // `rebalanceBase`, `selfSwap`, `rebalanceViaVenue` are PERMISSIONLESS — every safety bound is
    // re-verified ON-CHAIN regardless of caller (item 6). `configureTier`/`setVenueAllowed` stay
    // owner-gated (trust/governance decisions, not mechanical/safety-bounded actions).
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraVault
    /// @dev v3.3 PERMISSIONLESS CREATION (contracts/VAULT_STRATEGY_V3.md §11): the caller-gate
    ///      (`onlyKeeper`) is REMOVED — anyone may register a pool now, per the decided
    ///      "permissionless pool creation with team-curated emissions" spec. This does NOT weaken
    ///      any fund-safety invariant; it REPLACES the blanket caller-gate with two narrower,
    ///      admin-curated levers that address the SPECIFIC risks pool creation could otherwise pose:
    ///       1. (both regimes) the pool's QUOTE-side token must be team-allowlisted
    ///          (`allowedQuoteAssets`) — closes the "fake/self-referential quote asset" attack the
    ///          unified fee-routing self-swap (§9) would otherwise be exposed to (that self-swap
    ///          trusts the quote side is reasonably liquid).
    ///       2. (RWA only) `oracleFeed` must be a team-verified feed on `approvedRwaFeeds` — closes
    ///          the fake-oracle attack surface unique to RWA (no equivalent risk/registry for MEME).
    ///      Everything else about pool creation (band/tranche shape, share-token deployment) is
    ///      byte-identical to the prior gated behavior.
    function createBaseLimitPool(
        PoolKey calldata key,
        FeraTypes.Regime regime,
        address oracleFeed,
        uint160 sqrtPriceX96,
        bool quoteIsToken0_,
        string calldata name_,
        string calldata symbol_
    ) external returns (PoolId id) {
        id = key.toId();
        PoolInfo storage p = pools[id];
        require(!p.initialized, "init");

        // Curation lever 0 (BOTH regimes) — FIX H-1 (memo 09): the pool MUST route through the
        // Vault's own immutable FeraHook. Permissionless creation removed the `onlyKeeper` gate that
        // implicitly guaranteed a trusted keeper always passed the real hook; without this check a
        // caller could register a pool with `key.hooks == address(0)` (static fee) or an
        // attacker-deployed hook, which the real hook would NEVER govern — its cumulative-tick TWAP
        // would stay empty forever and `_poolTwapPrice` would fall back to atomically-manipulable
        // raw spot, voiding every self-swap `minOut` bound (§9, `selfSwap`, `rebalanceBase`,
        // `withdrawSingle`). This is the symmetric counterpart to FeraHook._beforeInitialize's
        // `sender == vault` requirement, and makes v4's `!isDynamicFee` zero-hook bypass moot.
        if (address(key.hooks) != address(hook)) revert WrongHook();

        // Curation lever 1 (BOTH regimes): reject an unallowlisted quote asset — see NatSpec above.
        address quoteToken = Currency.unwrap(quoteIsToken0_ ? key.currency0 : key.currency1);
        if (!allowedQuoteAssets[quoteToken]) revert QuoteAssetNotAllowed();

        // Curation lever 2 (RWA only): reject a zero/unapproved oracle feed. MEME has no oracle
        // dependency at all, so no registry check applies (item 2 of the decided spec).
        if (regime == FeraTypes.Regime.RWA) {
            if (oracleFeed == address(0) || !approvedRwaFeeds[oracleFeed]) revert RwaFeedNotApproved();
        }

        hook.registerRegime(key, regime);
        hook.setOracleFeed(id, oracleFeed);
        poolManager.initialize(key, sqrtPriceX96);

        p.key = key;
        p.regime = regime;
        p.oracleFeed = oracleFeed;
        p.marketOpen = regime == FeraTypes.Regime.MEME;
        p.initialized = true;
        p.trancheCount = 2; // tranche 0 = Steady, tranche 1 = Active (risk choice; INV-15 segregated)
        // v3.1 unified fee-routing config (§9): which side is the liquid quote asset. Immutable
        // post-creation — a pool's token roles never change.
        p.quoteIsToken0 = quoteIsToken0_;

        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 spacing = key.tickSpacing;
        _initBaseLimitTranche(id, 0, FeraConstants.TIER_STEADY, tick, spacing, name_, symbol_);
        _initBaseLimitTranche(id, 1, FeraConstants.TIER_ACTIVE, tick, spacing, name_, symbol_);

        emit StrategyAction(
            PoolId.unwrap(id), uint8(FeraTypes.StrategyKind.InitialMint), tick, tick, 0, bytes32("base+limit+idle")
        );
    }

    /// @dev Build one base+limit+idle tranche: a single wide BASE band (weight 100% — the first
    ///      deposit fills it; the IDLE reserve is established afterwards by `skimIdle`), its width
    ///      already vol-adaptive (§2 — a fresh pool's EWMA is seeded to 0 ⇒ the calm-pool floor
    ///      multiplier). The LIMIT band is deployed on demand by `rebalanceLimit` from reserve.
    function _initBaseLimitTranche(
        PoolId id,
        uint8 t,
        uint8 tier,
        int24 tick,
        int24 spacing,
        string calldata name_,
        string calldata symbol_
    ) internal {
        TrancheState storage tr = tranches[id][t];
        tr.exists = true;
        tr.share = _cloneShare(id, name_, symbol_, t);
        (int24 baseHalf, int24 limitHalf, uint16 idle) = _tierDefaults(tier);
        tierConfig[id][t] = TierConfig({tier: tier, baseHalfTicks: baseHalf, limitHalfTicks: limitHalf, idleBps: idle, set: true});
        int24 effHalf = _effectiveHalfWidth(id, baseHalf);
        (int24 lo, int24 hi) = _bandAround(tick, effHalf, spacing);
        _pushBand(tr, lo, hi, true, uint16(FeraConstants.BPS)); // BASE band
    }

    function _tierDefaults(uint8 tier) internal pure returns (int24 baseHalf, int24 limitHalf, uint16 idle) {
        if (tier == FeraConstants.TIER_STEADY) {
            return (FeraConstants.STEADY_BASE_HALF_TICKS, FeraConstants.STEADY_LIMIT_HALF_TICKS, FeraConstants.STEADY_IDLE_BPS);
        }
        if (tier == FeraConstants.TIER_ACTIVE) {
            return (FeraConstants.ACTIVE_BASE_HALF_TICKS, FeraConstants.ACTIVE_LIMIT_HALF_TICKS, FeraConstants.ACTIVE_IDLE_BPS);
        }
        revert BadTier();
    }

    /// @inheritdoc IFeraVault
    function configureTier(PoolId id, uint8 t, uint8 tier, uint16 idleBps) external onlyOwner {
        if (!pools[id].initialized) revert UnknownPool();
        if (t >= pools[id].trancheCount) revert UnknownTranche();
        TierConfig storage cfg = tierConfig[id][t];
        if (!cfg.set) revert NotBaseLimitPool();
        // Bounds live in code (the Gamma lesson): no config path can un-invest the vault.
        if (idleBps > FeraConstants.IDLE_BPS_MAX) revert IdleBpsOutOfBounds();
        (int24 baseHalf, int24 limitHalf,) = _tierDefaults(tier); // reverts BadTier on unknown tier
        cfg.tier = tier;
        cfg.baseHalfTicks = baseHalf;
        cfg.limitHalfTicks = limitHalf;
        cfg.idleBps = idleBps;
        emit TierConfigured(PoolId.unwrap(id), t, tier, idleBps);
    }

    /// @inheritdoc IFeraVault
    function setVolWidthMultBounds(uint256 minBps, uint256 maxBps) external onlyOwner {
        if (minBps == 0 || minBps > maxBps) revert WidthMultOutOfBounds();
        if (minBps < FeraConstants.VOL_WIDTH_MULT_MIN_LEGAL_BPS || maxBps > FeraConstants.VOL_WIDTH_MULT_MAX_LEGAL_BPS) {
            revert WidthMultOutOfBounds();
        }
        volWidthMultMinBps = minBps;
        volWidthMultMaxBps = maxBps;
        emit VolWidthMultBoundsUpdated(minBps, maxBps);
    }

    /// @inheritdoc IFeraVault
    function skimIdle(PoolId id, uint8 t) external onlyKeeper nonReentrant knownTranche(id, t) {
        TierConfig storage cfg = _requireBaseLimit(id, t);
        _checkpoint(id, t); // D-18: realize fees before touching the base
        poolManager.unlock(abi.encode(CB_SKIM_IDLE, id, t, abi.encode(uint256(cfg.idleBps))));
        emit StrategyAction(PoolId.unwrap(id), uint8(FeraTypes.StrategyKind.SkimIdle), 0, 0, 0, bytes32(0));
    }

    /// @inheritdoc IFeraVault
    /// @dev IDEMPOTENT (audited, contracts/THREAT_MODEL.md): only the FIRST out-of-range poke arms
    ///      `oorSince`; repeated pokes while still OOR are a no-op on the timer (the `if (== 0)`
    ///      guard below) — an attacker spamming this cannot advance/backdate the dwell clock in
    ///      either direction, so it cannot change WHEN `rebalanceBase`'s dwell gate is satisfied.
    function pokeOutOfRange(PoolId id, uint8 t) public knownTranche(id, t) returns (bool oor) {
        _requireBaseLimit(id, t);
        oor = _baseOutOfRange(id, t);
        if (oor) {
            if (oorSince[id][t] == 0) oorSince[id][t] = uint64(block.timestamp);
        } else {
            oorSince[id][t] = 0;
        }
    }

    /// @inheritdoc IFeraVault
    /// @dev v3: PERMISSIONLESS. Every bound (min-interval, TWAP sanity) is re-verified on-chain
    ///      regardless of caller; no function of `msg.sender` appears anywhere in this call.
    function rebalanceLimit(PoolId id, uint8 t) external nonReentrant knownTranche(id, t) {
        _requireBaseLimit(id, t);
        _requireRebalanceInterval(id, t); // R-15: bounded frequency (MEME shorter than RWA, both > 0)
        // Anti-whipsaw: never (re)deploy a limit onto a spot spike the TWAP disagrees with.
        if (_twapDeviationBps(id, FeraConstants.REBALANCE_TWAP_WINDOW_SEC) > FeraConstants.REBALANCE_TWAP_SANITY_BPS) {
            revert TwapOutOfBand();
        }
        _checkpoint(id, t);
        poolManager.unlock(abi.encode(CB_REBALANCE_LIMIT, id, t, bytes("")));
        lastRebalanceTs[id][t] = uint64(block.timestamp);
        emit StrategyAction(PoolId.unwrap(id), uint8(FeraTypes.StrategyKind.LimitDeploy), 0, 0, 0, bytes32(0));
    }

    /// @inheritdoc IFeraVault
    /// @dev v3: PERMISSIONLESS. Gate 1-4 are unchanged from v2; Gate 5 (execution slippage) is a
    ///      DIFFERENT bound from the NEW IL-budget cap (item 4 / FeraConstants.MAX_IL_BPS_PER_RECENTER):
    ///      Gate 5 bounds price-impact RATIO vs TWAP; the IL cap bounds the ABSOLUTE NAV-fraction any
    ///      one call's self-swap may put at risk. When the ideal rebalancing swap exceeds the IL
    ///      budget, `_cbRebalanceBase` clamps it (partial execution) instead of reverting — the base
    ///      band is still fully re-anchored (re-ticking alone realizes no IL, only a swap's price
    ///      impact does); the leftover imbalance is completed by a LATER call once the min-interval
    ///      has re-elapsed (via another `rebalanceBase`, a standalone `selfSwap`, or the swap-free
    ///      `rebalanceLimit`).
    function rebalanceBase(PoolId id, uint8 t, bool useSelfSwap) external nonReentrant knownTranche(id, t) {
        _requireBaseLimit(id, t);
        // Gate 1 — base OOR now (re-verified, not just at the last poke).
        if (!_baseOutOfRange(id, t)) revert NotOutOfRange();
        // Gate 2 — OOR sustained ≥ the regime DWELL (anti-whipsaw; price can snap back). v3: the
        // dwell is now a SEPARATE constant from the min-interval floor (Gate 3) — see `_oorDwell`.
        uint32 dwell = _oorDwell(id);
        uint64 since = oorSince[id][t];
        if (since == 0 || block.timestamp - since < dwell) revert OorNotPersistent();
        // Gate 3 — ≥ min-interval since the last rebalance (R-15: no unbounded frequency).
        _requireRebalanceInterval(id, t);
        // Gate 4 — TWAP-confirmed real move (TWAP also OOR AND spot within sanity of TWAP).
        _requireTwapConfirmedOor(id, t);

        _checkpoint(id, t);
        (uint256 vBefore,,) = _trancheValue(id, t);
        // v3 NEW: the IL budget this ONE call's self-swap may spend, in token1-notional terms.
        uint256 ilBudget = FullMath.mulDiv(vBefore, FeraConstants.MAX_IL_BPS_PER_RECENTER, FeraConstants.BPS);
        bool isPartial = abi.decode(
            poolManager.unlock(abi.encode(CB_REBALANCE_BASE, id, t, abi.encode(useSelfSwap, ilBudget))), (bool)
        );
        (uint256 vAfter,, int24 tick) = _trancheValue(id, t);
        // Gate 5 — execution value conservation (SWAP-SLIPPAGE bound, distinct from the IL cap above).
        if (vAfter * FeraConstants.BPS < vBefore * (FeraConstants.BPS - FeraConstants.MAX_REBALANCE_SLIPPAGE_BPS)) {
            revert RebalanceSlippage();
        }
        lastRebalanceTs[id][t] = uint64(block.timestamp);
        oorSince[id][t] = 0;
        FeraTypes.StrategyKind kind =
            isPartial ? FeraTypes.StrategyKind.BaseRecenterPartial : FeraTypes.StrategyKind.BaseRecenter;
        emit StrategyAction(PoolId.unwrap(id), uint8(kind), tick, tick, ilBudget, bytes32(0));
    }

    /// @notice Standalone bounded self-swap against the OWN v4 pool (ratio balancing). Executed output
    ///         re-verified ≥ (1 − MAX_REBALANCE_SLIPPAGE_BPS) × pool-TWAP-implied, else reverts. Spends
    ///         only the tranche's OWN reserve (no cross-tranche transfer). v3: PERMISSIONLESS, and
    ///         additionally bounded by the SAME per-call IL-budget notional cap `rebalanceBase` uses
    ///         (closes the loophole where a standalone call could otherwise finish, in one shot, what
    ///         a partial guarded recenter deliberately left capped) — a user-supplied `amountIn` over
    ///         budget REVERTS (`IlBudgetExceeded`) rather than being silently truncated.
    function selfSwap(PoolId id, uint8 t, bool zeroForOne, uint256 amountIn)
        external
        nonReentrant
        knownTranche(id, t)
        returns (uint256 amountOut)
    {
        _requireBaseLimit(id, t);
        _requireRebalanceInterval(id, t);
        TrancheState storage tr = tranches[id][t];
        uint256 have = zeroForOne ? tr.reserve0 : tr.reserve1;
        if (amountIn == 0 || amountIn > have) revert Slippage();

        (uint256 nav,,) = _trancheValue(id, t);
        uint256 ilBudget = FullMath.mulDiv(nav, FeraConstants.MAX_IL_BPS_PER_RECENTER, FeraConstants.BPS);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        uint256 notionalVal = zeroForOne ? FullMath.mulDiv(amountIn, priceX96, 1 << 96) : amountIn;
        if (notionalVal > ilBudget) revert IlBudgetExceeded();

        amountOut = abi.decode(
            poolManager.unlock(abi.encode(CB_SELF_SWAP, id, t, abi.encode(zeroForOne, amountIn))), (uint256)
        );
        lastRebalanceTs[id][t] = uint64(block.timestamp);
        emit StrategyAction(PoolId.unwrap(id), uint8(FeraTypes.StrategyKind.SelfSwap), 0, 0, amountOut, bytes32(0));
    }

    /// @inheritdoc IFeraVault
    /// @dev v3: PERMISSIONLESS. The venue allowlist (governance/trust decision) is the safety
    ///      boundary here, not the caller — anyone may TRIGGER a swap through an ALREADY-WHITELISTED
    ///      venue, bounded by the same on-chain TWAP-slippage check as the self-swap path.
    function rebalanceViaVenue(PoolId id, uint8 t, address venue, bool zeroForOne, uint256 amountIn)
        external
        nonReentrant
        knownTranche(id, t)
        returns (uint256 amountOut)
    {
        _requireBaseLimit(id, t);
        if (!rebalanceVenueAllowed[venue]) revert VenueNotAllowed();
        _requireRebalanceInterval(id, t);
        TrancheState storage tr = tranches[id][t];
        uint256 have = zeroForOne ? tr.reserve0 : tr.reserve1;
        if (amountIn == 0 || amountIn > have) revert Slippage(); // spend only OWN reserve (no cross-tranche)

        // SAME on-chain bound as the self-swap: output ≥ (1 − slippage) × pool-TWAP-implied.
        uint256 minOut = FullMath.mulDiv(
            _twapImpliedOut(id, zeroForOne, amountIn),
            FeraConstants.BPS - FeraConstants.MAX_REBALANCE_SLIPPAGE_BPS,
            FeraConstants.BPS
        );
        // RE-AUDIT FIX (05): a zero TWAP-implied floor cannot bound the swap (`amountOut < 0` is never
        // true) — reject rather than let a venue keep `amountIn` for near-zero output.
        if (minOut == 0) revert RebalanceSlippage();
        PoolInfo storage p = pools[id];
        address tokenIn = Currency.unwrap(zeroForOne ? p.key.currency0 : p.key.currency1);
        address tokenOut = Currency.unwrap(zeroForOne ? p.key.currency1 : p.key.currency0);

        uint256 balInBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(venue, amountIn);
        // Bounded external call. The venue is untrusted: we cap the pull via the exact approval, measure
        // BOTH sides by BALANCE DELTA (never trust the return value), reset the approval, and re-verify
        // the delta against the TWAP bound — so a malicious/deficient venue can only ever make us revert.
        IRebalanceVenue(venue).swapExactIn(tokenIn, tokenOut, amountIn, minOut, address(this));
        IERC20(tokenIn).forceApprove(venue, 0);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        if (amountOut < minOut) revert RebalanceSlippage();
        // RE-AUDIT FIX (05): debit the ACTUAL tokenIn spent (balance delta), symmetric to the output
        // measurement — a venue that under-pulls can no longer desync reserve accounting below the
        // physical balance. `spentIn ≤ amountIn ≤ reserve`, so the decrement cannot underflow.
        uint256 spentIn = balInBefore - IERC20(tokenIn).balanceOf(address(this));

        if (zeroForOne) {
            tr.reserve0 -= spentIn;
            tr.reserve1 += amountOut;
        } else {
            tr.reserve1 -= spentIn;
            tr.reserve0 += amountOut;
        }
        lastRebalanceTs[id][t] = uint64(block.timestamp);
        emit StrategyAction(PoolId.unwrap(id), uint8(FeraTypes.StrategyKind.VenueSwap), 0, 0, amountOut, bytes32(0));
    }

    /// @inheritdoc IFeraVault
    function setVenueAllowed(address venue, bool allowed) external onlyOwner {
        if (venue == address(0)) revert ZeroAddress();
        rebalanceVenueAllowed[venue] = allowed;
        emit VenueAllowed(venue, allowed);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // v3.3 — Permissionless pool creation: team-curation levers (contracts/VAULT_STRATEGY_V3.md
    // §11). `createBaseLimitPool` is now callable by anyone; these three onlyOwner-gated levers are
    // the SAFETY boundary that replaces the removed caller-gate — trust/curation decisions, exactly
    // like `setVenueAllowed` above, not mechanical/safety-bounded actions re-verified per call.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraVault
    /// @dev Team-set allowlist of acceptable QUOTE-side assets. `createBaseLimitPool` rejects any
    ///      pool whose designated quote token (per its `quoteIsToken0` argument) is not on this
    ///      list — for BOTH regimes (the unified fee-routing self-swap, §9, trusts the quote side to
    ///      be reasonably liquid regardless of which regime the pool is). This is what stops a
    ///      malicious permissionless creator from pairing a pool against a fake/self-referential/
    ///      illiquid "quote" token.
    function setAllowedQuoteAsset(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedQuoteAssets[token] = allowed;
        emit QuoteAssetAllowed(token, allowed);
    }

    /// @inheritdoc IFeraVault
    /// @dev Team-curated RWA oracle-feed registry (item 2 of the decided spec): the team verifies a
    ///      specific Chainlink feed off-chain (correct underlying, correct decimals, real liquidity/
    ///      reputable source) and only THEN approves it here. `createBaseLimitPool` rejects any RWA
    ///      pool whose `oracleFeed` is not on this registry — this is what stops a malicious
    ///      permissionless creator from binding a fake/self-deployed "oracle" contract that always
    ///      reports a favorable price. MEME pool creation never consults this registry at all (no
    ///      oracle dependency, so no fake-oracle risk exists to curate against).
    function approveRwaFeed(address feed, string calldata description) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress();
        approvedRwaFeeds[feed] = true;
        emit RwaFeedApproved(feed, description);
    }

    /// @inheritdoc IFeraVault
    /// @dev Removes a feed from the approved registry (e.g. a feed later found to be stale/
    ///      compromised/mis-verified). Does NOT retroactively affect any RWA pool already created
    ///      with this feed — `oracleFeed` is bound immutably at `createBaseLimitPool` time; revoking
    ///      only prevents NEW pools from being created against it going forward.
    function revokeRwaFeed(address feed) external onlyOwner {
        approvedRwaFeeds[feed] = false;
        emit RwaFeedRevoked(feed);
    }

    /// @inheritdoc IFeraVault
    /// @dev Item 3 of the decided spec. This flag is consulted ONLY by the off-chain esFERA
    ///      emissions pipeline (the Merkle-leaf builder that feeds `Distributor.postRoot` — see
    ///      `EmissionsController.sol`/`Distributor.sol`, which have NO on-chain notion of
    ///      per-pool eligibility at all: the pipeline decides which pools' LP/trader activity to
    ///      include in a given epoch's leaves entirely off-chain). It has NO on-chain effect
    ///      whatsoever on fee generation, `collectFees`, or the §9 unified fee-routing
    ///      perf-fee split — a non-eligible pool still generates and routes real revenue
    ///      (staker/treasury/ops) exactly like an eligible one; only whether esFERA emissions are
    ///      ever attributed to it is gated by this flag. Defaults FALSE for every pool (permissionless
    ///      or not) until the team explicitly opts it in.
    function setEmissionsEligible(PoolId id, bool eligible) external onlyOwner {
        if (!pools[id].initialized) revert UnknownPool();
        emissionsEligible[id] = eligible;
        emit EmissionsEligibilityChanged(PoolId.unwrap(id), eligible);
    }

    /// @inheritdoc IFeraVault
    /// @dev NEVER pausable (INV-11). Redeems into ONE token by first taking the pro-rata IN-KIND slice
    ///      (base + limit + idle) and then self-swapping the unwanted leg within the slippage bound. If
    ///      the swap cannot meet `minOut`, this reverts — and the user ALWAYS retains the unblockable
    ///      in-kind exit via `withdraw` (no swap, no venue). Output value ≤ pro-rata NAV by construction.
    function withdrawSingle(PoolId id, uint8 t, uint256 shares, address tokenOut, uint256 minOut)
        external
        nonReentrant
        knownTranche(id, t)
        returns (uint256 amountOut)
    {
        _requireBaseLimit(id, t);
        if (block.timestamp < lastDepositTs[id][t][msg.sender] + FeraConstants.DEPOSIT_COOLDOWN_SEC) {
            revert CooldownActive();
        }
        bool wantToken0 = tokenOut == Currency.unwrap(pools[id].key.currency0);
        if (!wantToken0 && tokenOut != Currency.unwrap(pools[id].key.currency1)) revert BadTier();

        _checkpoint(id, t);
        TrancheState storage tr = tranches[id][t];
        uint256 totalShares = IFeraShare(tr.share).totalSupply();

        // Pro-rata slice of held (non-banded) balances — round DOWN vs the exact pro-rata
        // `(pending+reserve)·shares/totalShares` (R-17 ratchet discipline: floor never over-pays the
        // withdrawer; dust stays with remaining holders). Debited reserve-first then pending.
        uint256 held0 = FullMath.mulDiv(shares, tr.pending0 + tr.reserve0, totalShares);
        uint256 held1 = FullMath.mulDiv(shares, tr.pending1 + tr.reserve1, totalShares);
        _debitHeldPreferReserve(tr, held0, held1);

        IFeraShare(tr.share).burn(msg.sender, shares); // CEI

        amountOut = abi.decode(
            poolManager.unlock(abi.encode(CB_WITHDRAW_SINGLE, id, t, abi.encode(shares, totalShares, wantToken0, held0, held1))),
            (uint256)
        );
        if (amountOut < minOut) revert SingleOutTooLow();
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        emit WithdrawSingle(PoolId.unwrap(id), msg.sender, tokenOut, amountOut, shares, t);
    }

    /// @dev Debit a pro-rata held slice from a tranche, reserve first then pending — mirrors the
    ///      physical spend so the swap in the callback draws the real tokens the withdrawer is owed.
    ///      `amt − min(amt,reserve) ≤ pending` always (amt ≤ pending+reserve), so no underflow.
    function _debitHeldPreferReserve(TrancheState storage tr, uint256 amt0, uint256 amt1) internal {
        uint256 r0 = amt0 < tr.reserve0 ? amt0 : tr.reserve0;
        tr.reserve0 -= r0;
        if (amt0 - r0 != 0) tr.pending0 -= (amt0 - r0);
        uint256 r1 = amt1 < tr.reserve1 ? amt1 : tr.reserve1;
        tr.reserve1 -= r1;
        if (amt1 - r1 != 0) tr.pending1 -= (amt1 - r1);
    }

    // ── rebalance gates + helpers ───────────────────────────────────────────────────────────

    function _requireBaseLimit(PoolId id, uint8 t) internal view returns (TierConfig storage cfg) {
        if (!pools[id].initialized) revert UnknownPool();
        cfg = tierConfig[id][t];
        if (!cfg.set) revert NotBaseLimitPool();
    }

    /// @dev Min spacing between successive rebalance actions (R-15). v3: DECOUPLED from the OOR
    ///      dwell (`_oorDwell`) — see FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC.
    function _minRebalanceInterval(PoolId id) internal view returns (uint32) {
        return pools[id].regime == FeraTypes.Regime.MEME
            ? FeraConstants.MEME_MIN_REBALANCE_INTERVAL_SEC
            : FeraConstants.RWA_MIN_REBALANCE_INTERVAL_SEC;
    }

    /// @dev v3 NEW: anti-whipsaw OOR-persistence requirement before a guarded base recenter may
    ///      fire — a SEPARATE, shorter (MEME) or equal (RWA) constant from the min-interval above
    ///      (item 5: MEME must be able to recenter reasonably often; RWA stays slow/calm).
    function _oorDwell(PoolId id) internal view returns (uint32) {
        return pools[id].regime == FeraTypes.Regime.MEME
            ? FeraConstants.MEME_OOR_DWELL_SEC
            : FeraConstants.RWA_OOR_DWELL_SEC;
    }

    function _requireRebalanceInterval(PoolId id, uint8 t) internal view {
        uint64 last = lastRebalanceTs[id][t];
        if (last != 0 && block.timestamp - last < _minRebalanceInterval(id)) revert RebalanceTooSoon();
    }

    /// @dev The BASE band index (isPrincipal, non-limit). Reverts if the tranche has no base band.
    function _baseIndex(TrancheState storage tr) internal view returns (uint256) {
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            if (tr.bands[i].isPrincipal && !tr.bands[i].isLimit) return i;
        }
        revert NotBaseLimitPool();
    }

    function _baseOutOfRange(PoolId id, uint8 t) internal view returns (bool) {
        (, int24 tick,,) = poolManager.getSlot0(id);
        TrancheState storage tr = tranches[id][t];
        Band storage b = tr.bands[_baseIndex(tr)];
        return tick < b.tickLower || tick >= b.tickUpper;
    }

    /// @dev Confirm the OOR is a real move, not a spot spike: the TWAP tick must ALSO be outside the
    ///      base band, and spot must be within the sanity band of the TWAP. Fresh pools (no elapsed
    ///      TWAP history) are allowed (spot IS the only price); dormant pools fail-closed (REC-9).
    function _requireTwapConfirmedOor(PoolId id, uint8 t) internal view {
        (int24 twapTick, bool ready) = hook.consultTwapTick(id, FeraConstants.REBALANCE_TWAP_WINDOW_SEC);
        if (!ready) return;
        (uint32 ageSec, bool has) = hook.twapObservationAge(id);
        if (has && ageSec > FeraConstants.TWAP_MAX_STALENESS_SEC) revert TwapStale();
        TrancheState storage tr = tranches[id][t];
        Band storage b = tr.bands[_baseIndex(tr)];
        if (twapTick >= b.tickLower && twapTick < b.tickUpper) revert OorNotPersistent(); // TWAP still in-range ⇒ spike
        if (_twapDeviationBps(id, FeraConstants.REBALANCE_TWAP_WINDOW_SEC) > FeraConstants.REBALANCE_TWAP_SANITY_BPS) {
            revert TwapOutOfBand();
        }
    }

    /// @dev Pool-TWAP-implied output for `amountIn` at the current TWAP (token1-per-token0, 1e18).
    ///      Reverts TwapStale on a dormant pool (fail-closed — no swap bound on a dead reference).
    function _twapImpliedOut(PoolId id, bool zeroForOne, uint256 amountIn) internal view returns (uint256) {
        uint256 price = _poolTwapPrice(id, FeraConstants.REBALANCE_TWAP_WINDOW_SEC);
        return zeroForOne ? FullMath.mulDiv(amountIn, price, 1e18) : FullMath.mulDiv(amountIn, 1e18, price);
    }

    /// @dev Execute a swap against the OWN pool, resolve deltas to the Vault. Does NOT touch reserve
    ///      accounting (callers do). When `enforceTwapBound` (all permissionless-rebalance paths), the
    ///      executed output is re-verified ≥ (1 − MAX_REBALANCE_SLIPPAGE_BPS) × pool-TWAP-implied — so
    ///      NO caller can ever move value beyond the on-chain bound. The user's own `withdrawSingle`
    ///      passes `false`: the protective bound there is the USER's `minOut` (checked by the caller),
    ///      not the TWAP.
    function _doSelfSwap(PoolId id, bool zeroForOne, uint256 amountIn, bool enforceTwapBound)
        internal
        returns (uint256 spent, uint256 amountOut)
    {
        if (amountIn == 0) return (0, 0);
        PoolInfo storage p = pools[id];
        uint256 minOut = enforceTwapBound
            ? FullMath.mulDiv(
                _twapImpliedOut(id, zeroForOne, amountIn),
                FeraConstants.BPS - FeraConstants.MAX_REBALANCE_SLIPPAGE_BPS,
                FeraConstants.BPS
            )
            : 0;
        // RE-AUDIT FIX (05): on the bounded paths (enforceTwapBound) a zero floor cannot bound the
        // swap; reject it. `withdrawSingle` passes enforceTwapBound=false by design (its bound is the
        // caller's own `minOut`), so it is unaffected — INV-11 in-kind exit stays unblockable.
        if (enforceTwapBound && minOut == 0) revert RebalanceSlippage();
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = poolManager.swap(
            p.key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), ""
        );
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        uint256 r0 = _resolveDelta(p.key.currency0, a0);
        uint256 r1 = _resolveDelta(p.key.currency1, a1);
        if (zeroForOne) {
            spent = uint256(uint128(-a0));
            amountOut = r1;
        } else {
            spent = uint256(uint128(-a1));
            amountOut = r0;
        }
        if (amountOut < minOut) revert RebalanceSlippage();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // v3 §2 — VOL-ADAPTIVE POSITION SIZING. Read the MEME EWMA the dynamic fee already reads (via
    // the hook's view); NEVER re-estimate it here.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @dev width = tierHalf × f(σ), clamped to the governance-set [min,max] multiplier band
    ///      (FeeLogic.widthMultiplierBps — same formula the MEME fee curve's σ-ramp mirrors).
    ///      RWA has no EWMA-vol signal wired in the hook (its dynamic fee uses oracle deviation, not
    ///      an EWMA) — multiplier fixed at 1x for RWA (a real stock's price is comparatively stable;
    ///      re-deriving a proxy vol estimator for RWA is explicitly OUT of this stage's scope —
    ///      flagged in contracts/OPEN_DECISIONS.md).
    function _effectiveHalfWidth(PoolId id, int24 tierHalf) internal view returns (int24) {
        if (pools[id].regime != FeraTypes.Regime.MEME) return tierHalf;
        (uint256 volEwmaX,,,) = hook.memeStateOf(id);
        uint256 multBps = FeeLogic.widthMultiplierBps(volEwmaX, volWidthMultMinBps, volWidthMultMaxBps);
        return int24(int256(FullMath.mulDiv(uint256(uint24(tierHalf)), multBps, FeraConstants.BPS)));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // v3 §3 — INVENTORY-DRIVEN LIMIT SKEW (deterministic; RWA additionally mean-reversion-biased
    // toward the Chainlink oracle). Formula (contracts/VAULT_STRATEGY_V3.md §3):
    //   r        = surplusValue / totalReserveValue ∈ [50%, 100%] (bps)   — how one-sided the reserve is
    //   invScore = clamp((r − 50%) × 2, 0, 100%)                          — 0 balanced, 100% one-sided
    //   [RWA only] devBps       = clamp((oracle−spot)/spot, ±ORACLE_BIAS_MAX_DEV_BPS)
    //              aligned      = surplus0 ? devBps : −devBps             — sign aligned to the CHOSEN side
    //              oracleScore  = clamp((aligned+MAX_DEV)/(2×MAX_DEV), 0, 100%)  — 0 disagrees, 100% agrees
    //              score        = (1−W)×invScore + W×oracleScore,  W = ORACLE_BIAS_WEIGHT_BPS (≤30%)
    //   [MEME]     score        = invScore
    //   skewBps  = LIMIT_SKEW_MIN_BPS + (LIMIT_SKEW_MAX_BPS − LIMIT_SKEW_MIN_BPS) × score
    // The oracle NEVER flips which side the limit deploys to (that side is fixed by `surplus0`,
    // i.e. by which token is actually in surplus) — it only modulates HOW FAR the skew leans within
    // the existing (5000,9500] bound, so the limit always deploys the real surplus.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    function _inventorySkewBps(PoolId id, uint8 t, uint160 sqrtPriceX96, bool surplus0) internal view returns (uint16) {
        TrancheState storage tr = tranches[id][t];
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        uint256 val0 = FullMath.mulDiv(tr.reserve0, priceX96, 1 << 96);
        uint256 val1 = tr.reserve1;
        uint256 total = val0 + val1;
        if (total == 0) return FeraConstants.LIMIT_SKEW_MIN_BPS;
        uint256 surplusVal = surplus0 ? val0 : val1;
        uint256 rBps = FullMath.mulDiv(surplusVal, FeraConstants.BPS, total);
        if (rBps < FeraConstants.BPS / 2) rBps = FeraConstants.BPS / 2; // floor: surplus is ≥ half by construction
        uint256 invScoreBps = (rBps - FeraConstants.BPS / 2) * 2;
        if (invScoreBps > FeraConstants.BPS) invScoreBps = FeraConstants.BPS;

        uint256 combinedBps = invScoreBps;
        if (pools[id].regime == FeraTypes.Regime.RWA) {
            (uint256 oracle, bool ok) = _tryReadOracle(id);
            if (ok) {
                uint256 spot = FullMath.mulDiv(priceX96, 1e18, 1 << 96);
                if (spot != 0) {
                    int256 maxDev = int256(FeraConstants.ORACLE_BIAS_MAX_DEV_BPS);
                    int256 devBps = (int256(oracle) - int256(spot)) * int256(FeraConstants.BPS) / int256(spot);
                    if (devBps > maxDev) devBps = maxDev;
                    if (devBps < -maxDev) devBps = -maxDev;
                    int256 aligned = surplus0 ? devBps : -devBps;
                    uint256 oracleScoreBps = uint256(((aligned + maxDev) * int256(FeraConstants.BPS)) / (2 * maxDev));
                    uint256 w = FeraConstants.ORACLE_BIAS_WEIGHT_BPS;
                    combinedBps = ((FeraConstants.BPS - w) * invScoreBps + w * oracleScoreBps) / FeraConstants.BPS;
                }
            }
        }

        uint256 span = FeraConstants.LIMIT_SKEW_MAX_BPS - FeraConstants.LIMIT_SKEW_MIN_BPS;
        uint256 skew = FeraConstants.LIMIT_SKEW_MIN_BPS + FullMath.mulDiv(span, combinedBps, FeraConstants.BPS);
        return uint16(skew);
    }

    /// @dev Non-reverting Chainlink read (unlike the legacy strict oracle gate this replaces): the
    ///      skew bias degrades to pure-inventory (never reverts the rebalance) on a stale/absent/
    ///      malformed feed — matching the "never revert a mechanical action for an oracle hiccup"
    ///      discipline the fee overlay already follows.
    function _tryReadOracle(PoolId id) internal view returns (uint256 price, bool ok) {
        address feed = pools[id].oracleFeed;
        if (feed == address(0)) return (0, false);
        try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) return (0, false);
            if (block.timestamp - updatedAt > FeraConstants.ORACLE_STALENESS_MAX) return (0, false);
            uint8 dec = IAggregatorV3(feed).decimals();
            price = uint256(answer) * (10 ** (18 - dec));
            ok = true;
        } catch {
            return (0, false);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Market-hours mirror (feeds the hook's RWA fee overlay only — no on-chain Vault gate consumes
    // it in v3; the legacy RWA oracle-recenter/widen/partialWithdraw gates that used to are removed).
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @dev Market-hours check (SEC-3 #7 / §10). Combines, in fail-static order: (1) keeper HOLIDAY
    ///      flag — force-closes; (2) keeper market-hours flag; (3) an on-chain UTC weekly SCHEDULE
    ///      bitmap — 168 bits, bit `h` = "open at hour-of-week h" (0 ⇒ keeper flag governs).
    function _isMarketOpen(PoolId id) internal view returns (bool) {
        PoolInfo storage p = pools[id];
        if (p.holiday) return false;
        if (!p.marketOpen) return false;
        uint256 sched = p.scheduleBitmap;
        if (sched == 0) return true;
        // slither-disable-next-line weak-prng — hour-of-week calendar index (modulo), not randomness.
        uint256 hourOfWeek = (block.timestamp / 3_600) % 168;
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
            // ever reached from the deposit gate + rebalance gates, NEVER a swap — INV-2) instead of
            // trusting it. A single (permissionless) swap refreshes the head and re-arms these paths.
            (uint32 ageSec, bool has) = hook.twapObservationAge(id);
            if (has && ageSec > FeraConstants.TWAP_MAX_STALENESS_SEC) revert TwapStale();
            sqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);
        } else {
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
        if (action == CB_SKIM_IDLE) return _cbSkimIdle(id, t, payload);
        if (action == CB_REBALANCE_LIMIT) return _cbRebalanceLimit(id, t);
        if (action == CB_REBALANCE_BASE) return _cbRebalanceBase(id, t, payload);
        if (action == CB_SELF_SWAP) return _cbSelfSwap(id, t, payload);
        if (action == CB_WITHDRAW_SINGLE) return _cbWithdrawSingle(id, t, payload);
        return _cbRouteFeeSwap(id, payload); // CB_ROUTE_FEE_SWAP
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
            // settle) when reserve==0. Ratio-matching is preserved: every band scales by the same `f`.
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

    // ── base+limit+idle callbacks (all tranche-scoped via _salt — INV-15) ───────────────────

    /// @dev Pull the IDLE fraction of the base band into reserve (value-conserving band→reserve).
    function _cbSkimIdle(PoolId id, uint8 t, bytes memory payload) internal returns (bytes memory) {
        uint256 idleBps = abi.decode(payload, (uint256));
        TrancheState storage tr = tranches[id][t];
        Band storage b = tr.bands[_baseIndex(tr)];
        uint128 pull = uint128(FullMath.mulDiv(b.liquidity, idleBps, FeraConstants.BPS));
        if (pull != 0) {
            (uint256 o0, uint256 o1) = _modifyBand(id, t, b.tickLower, b.tickUpper, -int256(uint256(pull)));
            b.liquidity -= pull;
            tr.reserve0 += o0;
            tr.reserve1 += o1;
        }
        return "";
    }

    /// @dev LIMIT-FIRST: collect the (filled) limit band(s) into reserve, then redeploy ONE limit on
    ///      the surplus side near spot from reserve — swap-free. Width is vol-adaptive (§2); skew is
    ///      inventory-driven (§3, RWA additionally oracle-mean-reversion-biased). Reuses a spent slot.
    function _cbRebalanceLimit(PoolId id, uint8 t) internal returns (bytes memory) {
        TrancheState storage tr = tranches[id][t];
        uint256 reuse = type(uint256).max;
        uint256 n = tr.bands.length;
        for (uint256 i; i < n; ++i) {
            Band storage lb = tr.bands[i];
            if (!lb.isLimit) continue;
            if (lb.liquidity != 0) {
                (uint256 o0, uint256 o1) = _modifyBand(id, t, lb.tickLower, lb.tickUpper, -int256(uint256(lb.liquidity)));
                lb.liquidity = 0;
                tr.reserve0 += o0;
                tr.reserve1 += o1;
            }
            reuse = i;
        }

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(id);
        TierConfig storage cfg = tierConfig[id][t];
        PoolInfo storage p = pools[id];
        bool surplus0 = _valueInToken1(sqrtPriceX96, tr.reserve0, 0) >= tr.reserve1;
        uint16 skewBps = _inventorySkewBps(id, t, sqrtPriceX96, surplus0);
        int24 halfW = _effectiveHalfWidth(id, cfg.limitHalfTicks);
        (int24 lower, int24 upper) = _limitTicks(tick, p.key.tickSpacing, halfW, skewBps, surplus0);

        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), tr.reserve0, tr.reserve1
        );
        if (dL != 0) {
            uint256 bal0 = p.key.currency0.balanceOfSelf();
            uint256 bal1 = p.key.currency1.balanceOfSelf();
            _modifyBand(id, t, lower, upper, int256(uint256(dL)));
            // RE-AUDIT FIX (05): floored-at-0 reserve debit (v4 mint round-up can exceed reserve by
            // dust; the prior unguarded `-=` could underflow-revert an otherwise-valid limit redeploy).
            _absorbDepositOverage(
                tr, bal0 - p.key.currency0.balanceOfSelf(), bal1 - p.key.currency1.balanceOfSelf()
            );
            if (reuse != type(uint256).max) {
                Band storage slot = tr.bands[reuse];
                slot.tickLower = lower;
                slot.tickUpper = upper;
                slot.liquidity = dL;
            } else {
                require(tr.bands.length < FeraConstants.MAX_BANDS_PER_TRANCHE, "bands");
                tr.bands.push(
                    Band({tickLower: lower, tickUpper: upper, liquidity: dL, isPrincipal: false, weightBps: 0, isLimit: true})
                );
            }
        }
        return "";
    }

    /// @dev GUARDED base recenter: close the base into reserve, re-anchor its ticks at spot (vol-
    ///      adaptive width, §2), optionally self-swap the turned-over inventory toward 50/50 —
    ///      BOUNDED by the IL budget (§4: `_balanceReserve` clamps rather than reverting, returning
    ///      whether it was capped) — and re-mint the base from reserve. Value-conservation (Gate 5,
    ///      a DIFFERENT, execution-slippage bound) is enforced end-to-end by the caller.
    function _cbRebalanceBase(PoolId id, uint8 t, bytes memory payload) internal returns (bytes memory) {
        (bool selfSwapOn, uint256 ilBudget) = abi.decode(payload, (bool, uint256));
        TrancheState storage tr = tranches[id][t];
        PoolInfo storage p = pools[id];
        Band storage b = tr.bands[_baseIndex(tr)];

        if (b.liquidity != 0) {
            (uint256 g0, uint256 g1) = _modifyBand(id, t, b.tickLower, b.tickUpper, -int256(uint256(b.liquidity)));
            b.liquidity = 0;
            tr.reserve0 += g0;
            tr.reserve1 += g1;
        }

        // Optionally rebalance the (now one-sided) reserve toward 50/50, IL-budget-bounded (§4) —
        // this MOVES the pool spot (only up to the budget; NEVER the full imbalance if that exceeds it).
        bool isPartial;
        if (selfSwapOn) {
            (uint160 sqrtPre,,,) = poolManager.getSlot0(id);
            isPartial = _balanceReserve(id, t, sqrtPre, ilBudget);
        }

        // RE-AUDIT FIX (05): RE-READ spot AFTER the self-swap so the base is anchored + SIZED at the
        // TRUE post-swap price (avoids the stale-price mint/reserve-underflow bug the prior re-audit
        // caught). Vol-adaptive width (§2) is re-derived fresh at this (possibly moved) price/EWMA.
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(id);
        int24 effHalf = _effectiveHalfWidth(id, tierConfig[id][t].baseHalfTicks);
        (int24 lo, int24 hi) = _bandAround(tick, effHalf, p.key.tickSpacing);
        b.tickLower = lo;
        b.tickUpper = hi;

        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), tr.reserve0, tr.reserve1
        );
        if (dL != 0) {
            uint256 bal0 = p.key.currency0.balanceOfSelf();
            uint256 bal1 = p.key.currency1.balanceOfSelf();
            _modifyBand(id, t, lo, hi, int256(uint256(dL)));
            // RE-AUDIT FIX (05): debit the ACTUAL v4 spend from reserve, floored-at-0 then absorbed from
            // pending (mirror of the deposit path's `_absorbDepositOverage`). v4 rounds the mint charge
            // UP, so `used` can exceed reserve by dust; the prior unguarded `-=` underflow-reverted.
            _absorbDepositOverage(
                tr, bal0 - p.key.currency0.balanceOfSelf(), bal1 - p.key.currency1.balanceOfSelf()
            );
            b.liquidity = dL;
        }
        return abi.encode(isPartial);
    }

    /// @dev Bounded self-swap of the reserve toward 50/50 value (for the symmetric base), CAPPED at
    ///      `ilBudget` (token1-notional) per §4 — if the ideal balancing amount exceeds the budget,
    ///      only `ilBudget`-worth is swapped (a PARTIAL rebalance; `capped` is returned true) and the
    ///      remainder stays in reserve for a later action. PROVABLY BOUNDED: a swap can never realize
    ///      more loss than the value it puts at risk (amountOut ≥ 0 always), so bounding the notional
    ///      to `ilBudget` trivially bounds the worst-case realized loss to ≤ `ilBudget` regardless of
    ///      how large the underlying price gap was.
    function _balanceReserve(PoolId id, uint8 t, uint160 sqrtPriceX96, uint256 ilBudget) internal returns (bool capped) {
        TrancheState storage tr = tranches[id][t];
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        uint256 val0 = FullMath.mulDiv(tr.reserve0, priceX96, 1 << 96); // reserve0 valued in token1
        if (val0 > tr.reserve1) {
            uint256 idealVal = (val0 - tr.reserve1) / 2;
            uint256 boundedVal = idealVal > ilBudget ? ilBudget : idealVal;
            capped = boundedVal < idealVal;
            uint256 amt0 = FullMath.mulDiv(boundedVal, 1 << 96, priceX96);
            if (amt0 > tr.reserve0) amt0 = tr.reserve0;
            if (amt0 != 0) {
                (uint256 spent, uint256 out) = _doSelfSwap(id, true, amt0, true);
                tr.reserve0 -= spent;
                tr.reserve1 += out;
            }
        } else if (tr.reserve1 > val0) {
            uint256 idealVal = (tr.reserve1 - val0) / 2;
            uint256 boundedVal = idealVal > ilBudget ? ilBudget : idealVal;
            capped = boundedVal < idealVal;
            uint256 amt1 = boundedVal > tr.reserve1 ? tr.reserve1 : boundedVal;
            if (amt1 != 0) {
                (uint256 spent, uint256 out) = _doSelfSwap(id, false, amt1, true);
                tr.reserve1 -= spent;
                tr.reserve0 += out;
            }
        }
    }

    function _cbSelfSwap(PoolId id, uint8 t, bytes memory payload) internal returns (bytes memory) {
        (bool zeroForOne, uint256 amountIn) = abi.decode(payload, (bool, uint256));
        (uint256 spent, uint256 out) = _doSelfSwap(id, zeroForOne, amountIn, true);
        TrancheState storage tr = tranches[id][t];
        if (zeroForOne) {
            tr.reserve0 -= spent;
            tr.reserve1 += out;
        } else {
            tr.reserve1 -= spent;
            tr.reserve0 += out;
        }
        return abi.encode(out);
    }

    /// @dev v3.1 unified fee-routing (§9): bounded self-swap of a NATIVE-side perf fee into the
    ///      pool's quote asset. Reuses `_doSelfSwap` UNCHANGED (`enforceTwapBound=true` — same
    ///      TWAP-derived minOut, same MAX_REBALANCE_SLIPPAGE_BPS bound as rebalancing). Deliberately
    ///      does NOT touch `tr.reserve0/1` (unlike `_cbSelfSwap`) — a perf fee is not tranche reserve;
    ///      it is realized fee income already earmarked for distribution. `amountIn` is bounded by
    ///      the caller to EXACTLY the fee amount collected from this pool/tranche's own checkpoint
    ///      (never inflatable, never another pool's liquidity).
    function _cbRouteFeeSwap(PoolId id, bytes memory payload) internal returns (bytes memory) {
        (bool zeroForOne, uint256 amountIn) = abi.decode(payload, (bool, uint256));
        (, uint256 out) = _doSelfSwap(id, zeroForOne, amountIn, true);
        return abi.encode(out);
    }

    /// @dev Single-coin redemption: remove the pro-rata band slice into the Vault, add the pre-debited
    ///      held slice, then self-swap the unwanted leg into `tokenOut` (bounded). Output value ≤
    ///      pro-rata NAV by construction (a swap only loses value). Reserve is untouched — the swapped
    ///      tokens are the withdrawer's own pro-rata slice.
    function _cbWithdrawSingle(PoolId id, uint8 t, bytes memory payload) internal returns (bytes memory) {
        (uint256 shares, uint256 totalShares, bool wantToken0, uint256 held0, uint256 held1) =
            abi.decode(payload, (uint256, uint256, bool, uint256, uint256));
        TrancheState storage tr = tranches[id][t];
        uint256 out0 = held0;
        uint256 out1 = held1;
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
        uint256 single;
        if (wantToken0) {
            if (out1 != 0) {
                (, uint256 got) = _doSelfSwap(id, false, out1, false);
                out0 += got;
            }
            single = out0;
        } else {
            if (out0 != 0) {
                (, uint256 got) = _doSelfSwap(id, true, out0, false);
                out1 += got;
            }
            single = out1;
        }
        return abi.encode(single);
    }

    /// @dev Skewed LIMIT ticks near spot: mostly on the surplus side, straddling spot by a sliver
    ///      (`inner`) so it is NEVER strictly single-sided (it holds a rebalancing sliver of the other
    ///      token). surplus token0 ⇒ band above spot (sells token0 as price rises); surplus token1 ⇒
    ///      band below spot (sells token1 as price falls). Clamped to the usable tick range.
    function _limitTicks(int24 tick, int24 spacing, int24 halfW, uint16 skewBps, bool surplus0)
        internal
        pure
        returns (int24 lower, int24 upper)
    {
        int24 inner = int24(int256(halfW) * int256(uint256(FeraConstants.BPS - skewBps)) / int256(FeraConstants.BPS));
        if (surplus0) {
            lower = _floorTick(tick - inner, spacing);
            upper = _ceilTick(tick + halfW, spacing);
        } else {
            lower = _floorTick(tick - halfW, spacing);
            upper = _ceilTick(tick + inner, spacing);
        }
        int24 minT = TickMath.minUsableTick(spacing);
        int24 maxT = TickMath.maxUsableTick(spacing);
        if (lower < minT) lower = minT;
        if (upper > maxT) upper = maxT;
        if (upper <= lower) upper = lower + spacing; // degenerate guard
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
        tr.bands.push(
            Band({tickLower: lower, tickUpper: upper, liquidity: 0, isPrincipal: principal, weightBps: weightBps, isLimit: false})
        );
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
    // Admin — deposit pause ONLY (INV-11); launchpad class gated off (v1); bounded gate setters
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

    /// @notice Keeper flags a scheduled-event session (earnings before next open — D-M11 legacy;
    ///         reserved, no on-chain consumer in v3).
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
    ///         Backend marketHours keepers, `ops/reconcile`, and the API can query it WITHOUT
    ///         reproducing the holiday/keeper-flag/schedule-bitmap logic off-chain. Pure view.
    function isMarketOpen(PoolId id) external view returns (bool) {
        return _isMarketOpen(id);
    }

    /// @notice F-12: whether a keeper-flagged scheduled-event session (D-M11 legacy) is active.
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

    /// @notice Full band descriptor incl. the base/limit role (isPrincipal ⇒ BASE; isLimit ⇒ the
    ///         inventory-skewed LIMIT; neither ⇒ unused in v3).
    function bandInfo(PoolId id, uint8 t, uint256 index)
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, bool isPrincipal, bool isLimit)
    {
        Band storage b = tranches[id][t].bands[index];
        return (b.tickLower, b.tickUpper, b.liquidity, b.isPrincipal, b.isLimit);
    }

    // ── base+limit+idle views ───────────────────────────────────────────────────────────────
    function tierOf(PoolId id, uint8 t)
        external
        view
        returns (uint8 tier, int24 baseHalfTicks, int24 limitHalfTicks, uint16 idleBps, bool set)
    {
        TierConfig storage c = tierConfig[id][t];
        return (c.tier, c.baseHalfTicks, c.limitHalfTicks, c.idleBps, c.set);
    }

    function outOfRangeSince(PoolId id, uint8 t) external view returns (uint64) {
        return oorSince[id][t];
    }

    /// @notice The IDLE reserve balances (uninvested buffer) of a (pool,tranche).
    function idleReserves(PoolId id, uint8 t) external view returns (uint256 reserve0, uint256 reserve1) {
        TrancheState storage tr = tranches[id][t];
        return (tr.reserve0, tr.reserve1);
    }

    function isVenueAllowed(address venue) external view returns (bool) {
        return rebalanceVenueAllowed[venue];
    }

    /// @notice v3.1 unified fee-routing (§9): whether `poolId`'s token0 is the liquid QUOTE asset
    ///         (WETH/USDG-like) — the complementary token is the pool's NATIVE/project token. Set
    ///         once at `createBaseLimitPool`, immutable thereafter.
    function quoteIsToken0(PoolId id) external view returns (bool) {
        return pools[id].quoteIsToken0;
    }

    function volWidthMultBounds() external view returns (uint256 minBps, uint256 maxBps) {
        return (volWidthMultMinBps, volWidthMultMaxBps);
    }
}
