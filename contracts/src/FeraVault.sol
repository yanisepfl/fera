// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IFeraVault} from "./interfaces/IFeraVault.sol";
import {IFeraShare} from "./interfaces/IFeraShare.sol";
import {IFeraHook} from "./interfaces/IFeraHook.sol";
import {IRevenueDistributor} from "./interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "./interfaces/IAnchorStaking.sol";
import {FeraTypes} from "./libraries/FeraTypes.sol";
import {FeraConstants} from "./libraries/FeraConstants.sol";
import {VaultOps} from "./libraries/VaultOps.sol";
import {VaultMath} from "./libraries/VaultMath.sol";
import {VaultFees} from "./libraries/VaultFees.sol";
import {VaultRwa} from "./libraries/VaultRwa.sol";
import {VaultActions} from "./libraries/VaultActions.sol";
import {Band, TierConfig, TrancheState, PoolInfo} from "./libraries/VaultTypes.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
///          - v3.4   : ALL position-moving strategy actions (`rebalanceLimit`/`rebalanceBase`/
///            `selfSwap`/`rebalanceViaVenue`/`rebalanceRwaOracle`/`defendRwaOffHours`/`skimIdle`)
///            are KEEPER-ONLY (founder decision, reversing v3 §6: even swap-free actions carry a
///            residual timing-choice edge — zero grief surface beats bounded grief surface). Every
///            on-chain bound (interval, dwell, TWAP-confirmation, execution-slippage, IL-cap) is
///            still verified — as a check on keeper mistakes/compromise. ONLY `pokeOutOfRange`
///            stays permissionless: it MOVES NOTHING (an idempotent OOR-timer observation, audited
///            un-gameable) and lets anyone/UIs surface state. Withdraw/deposit/collectFees are of
///            course not strategy actions and remain open (withdraw NEVER gated, INV-11).
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

    /// @notice Rate-limit (seconds) between keeper-only standalone swaps (selfSwap / rebalanceViaVenue).
    ///         DEFAULT 0 = NO throttle (the keeper is trusted, and every call is still bounded by the
    ///         per-call IL-budget + the ≤1% TWAP-slippage check). Governance can dial a throttle back in
    ///         via setKeeperSwapInterval — defense-in-depth against keeper-KEY compromise — without a
    ///         redeploy. The permissionless swap-FREE cadence (rebalanceLimit) keeps its own interval.
    uint32 public keeperSwapInterval; // default 0 (off)
    event KeeperSwapIntervalSet(uint32 intervalSeconds);

    // Storage structs (Band / TierConfig / TrancheState / PoolInfo) live in
    // `libraries/VaultTypes.sol` so the size-split libraries (VaultOps) can receive `storage`
    // references to the vault's own state via public-library delegatecall. The storage LAYOUT is
    // unchanged — layout is fixed by the state-variable declaration order below + each struct's field
    // order/types, all preserved; only the struct declaration site moved out of this contract.

    mapping(PoolId => PoolInfo) internal pools;
    mapping(PoolId => mapping(uint256 => TrancheState)) internal tranches;
    /// @dev Per-(pool,tranche) tier config, OOR dwell clock, rebalance min-interval clock, and the
    ///      governance venue allowlist.
    mapping(PoolId => mapping(uint256 => TierConfig)) internal tierConfig;
    mapping(PoolId => mapping(uint256 => uint64)) internal oorSince; // base out-of-range since (0 = in range)
    mapping(PoolId => mapping(uint256 => uint64)) internal lastRebalanceTs; // R-15 GENERAL min-interval clock
    /// @dev V3-HARDENING (§5.1): DEDICATED clock for the IL-realising BASE-RECENTER family
    ///      (`rebalanceBase`, RWA `rebalanceRwaOracle`, RWA `defendRwaOffHours`), SEPARATE from the
    ///      general `lastRebalanceTs`. Gated by MEME_BASE_RECENTER_MIN_INTERVAL_SEC (6h MEME) so the
    ///      base recenter fires RARELY (do-not-chase-the-pump) AND is never starved by cheap
    ///      swap-free `rebalanceLimit` spam resetting a shared clock (closes OD-13).
    mapping(PoolId => mapping(uint256 => uint64)) internal lastBaseRecenterTs;
    mapping(address => bool) public rebalanceVenueAllowed;
    /// @dev PARAMS.md#DEPOSIT_COOLDOWN_SEC: per-(pool,tranche,user) last deposit; blocks only that
    ///      user's own redemption for 1h (narrow — no INV-11 tension).
    mapping(PoolId => mapping(uint256 => mapping(address => uint64))) public lastDepositTs;

    /// @notice Owner-set allowlist exempting an address from the FULL depositor cooldown in `withdraw`
    ///         and `withdrawSingle` (below), and from having its own `FeraShare.transferLockUntil`
    ///         armed on deposit. Exists for a SINGLE reason: a future aggregator-style contract (e.g.
    ///         a diversified index vault) that deposits into this vault as ONE shared address on
    ///         behalf of many end-users would otherwise have the anti-flash-loan cooldown re-armed by
    ///         every unrelated user's deposit into it — freezing that aggregator's withdrawals (and,
    ///         via the transfer lock, its `emergencyRedeemInKind`-style member-share transfers) from
    ///         ALL its own depositors, a liveness griefing vector, not a fund-safety one (see
    ///         contracts/INDEX_VAULT_SPEC.md §12). Exemption is narrow and inert by default (empty
    ///         mapping, opt-in per address, owner/timelock-gated):
    ///           - `withdraw`/`withdrawSingle`: swaps the full `DEPOSIT_COOLDOWN_SEC` wait for a
    ///             SHORTER but NON-ZERO floor (`VaultMath.exemptWithdrawFloorSec` — the address's
    ///             regime-JIT window + margin, shared by BOTH withdrawal paths so they cannot drift
    ///             apart — audit finding, low) past its OWN last deposit. Finding-2 hardening: a full bypass
    ///             would let an exempt address deposit-then-instantly-withdraw in one tx, forcing its
    ///             own mandatory fee checkpoint to land inside the JIT-forfeiture window it itself
    ///             just armed and donate its own fees away — this floor closes THAT self-inflicted
    ///             round trip while still avoiding the full hour-long shared-clock wait. It is
    ///             NOT a general guarantee against every JIT-forfeiture window: `FeraHook`'s JIT
    ///             clock is keyed per (pool, tranche, band) — SHARED across every depositor and the keeper,
    ///             not per-depositor (THREAT_MODEL.md §10.1 "Vault self-interaction" / V2-3) — so a
    ///             DIFFERENT depositor's ordinary deposit, or a keeper rebalance re-mint, occurring
    ///             AFTER this floor has already elapsed can still re-arm the same band and cause this
    ///             address's own withdraw-time checkpoint to forfeit fees, same as any other
    ///             withdrawal (audit finding, medium — v3.5.1). For MEME pools this recurs routinely,
    ///             not just adversarially: `MEME_MIN_REBALANCE_INTERVAL_SEC` (the keeper's minimum
    ///             rebalance cadence) exactly equals `JIT_PENALTY_WINDOW_MEME`. Bounded and fee-only
    ///             in every case — never fund-theft, never a blocked exit (INV-1''/INV-11).
    ///           - `deposit`: skips arming `transferLockUntil` for this address at all (Finding-3
    ///             hardening — the exemption would otherwise be defeated the moment the Index needs a
    ///             raw share `transfer`, not `burn`, to move a member's shares).
    ///         Every OTHER guard on `withdraw`/`withdrawSingle` (share balance, NAV-priced pro-rata
    ///         redemption, `minAmount0`/`minAmount1`/`minOut` slippage, `nonReentrant`, `notPaused`,
    ///         `knownTranche`) applies to an exempt address identically to anyone else.
    mapping(address => bool) public cooldownExempt;

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

    /// @notice v3.5 HARDENING (audit finding, cross-contract PoolManager reentrancy): per-pool
    ///         allowlist gating whether the AUTOMATED KEEPER may act on it at all. `createBaseLimitPool`
    ///         is permissionless — anyone can register a pool whose native (non-quote) token has an
    ///         arbitrary `transfer()` hook. Because v4's `PoolManager` uses a single global unlock flag
    ///         (not per-pool), a hostile hook firing during one of this vault's own token transfers
    ///         (inside `_modifyBand`'s settle/take) could reenter `PoolManager.swap()`/`modifyLiquidity()`
    ///         on ANY pool while the swap-free rebalance callbacks (`cbRebalanceLimit` et al.) are
    ///         mid-flight, then unwind before the callback's own fresh `getSlot0()` read — defeating the
    ///         value-conservation checks. `allowedQuoteAssets` already vets the QUOTE side; this vets
    ///         whether the WHOLE pool (hence both its tokens) is trusted enough for unattended automation
    ///         — same curation-lever pattern, onlyOwner-gated (`setKeeperActive`). Defaults FALSE for
    ///         every pool, including ones created before this flag existed: deposits/withdrawals/swaps
    ///         are completely unaffected either way (only `onlyKeeper` functions consult it) — a pool
    ///         simply gets no automated rebalancing until the team has reviewed its native token and
    ///         opted it in.
    mapping(PoolId => bool) public keeperActive;

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
    uint8 internal constant CB_RWA_ORACLE_RECENTER = 10; // v3-hardening (§5.1): RWA in-hours oracle-anchored base recenter (swap-free)
    uint8 internal constant CB_RWA_DEFEND = 11; // v3-hardening (§5.1): RWA off-hours/event WIDEN + partial-withdraw defense (swap-free)

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

    /// @dev Finding-1 hardening: blocks EVERY onlyKeeper pool-touching action until the owner has
    ///      explicitly reviewed and activated this specific pool (see `keeperActive` NatSpec).
    modifier keeperReady(PoolId id) {
        if (!keeperActive[id]) revert PoolNotKeeperActive();
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
        // Finding-3 hardening: an exempt address's OWN shares never need the outgoing-transfer lock
        // armed in the first place (the whole point of the exemption is that this address's
        // withdrawals/transfers must not be gated by a clock unrelated depositors keep re-arming) —
        // this is what lets a future Index's `emergencyRedeemInKind` (raw `FeraShare.transfer`, not
        // `burn`) actually move member shares once granted the exemption. Any transferLockUntil
        // armed BEFORE an address became exempt is untouched here and simply expires on its own
        // (extend-only, bounded by DEPOSIT_COOLDOWN_SEC from that earlier deposit).
        if (!cooldownExempt[msg.sender]) {
            IFeraShare(tr.share).setTransferLock(msg.sender, uint64(block.timestamp) + FeraConstants.DEPOSIT_COOLDOWN_SEC);
        }

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
        // Finding-2 hardening: an exempt address still waits its regime's JIT window + margin past
        // its OWN last deposit (see `_exemptWithdrawFloorSec` -> shared `VaultMath.exemptWithdrawFloorSec`
        // / EXEMPT_WITHDRAW_MARGIN_SEC NatSpec) — shorter than the full cooldown, but never zero, so
        // it cannot harvest a JIT window it just armed itself.
        uint256 requiredDelay =
            cooldownExempt[msg.sender] ? _exemptWithdrawFloorSec(id) : FeraConstants.DEPOSIT_COOLDOWN_SEC;
        if (block.timestamp < lastDepositTs[id][t][msg.sender] + requiredDelay) {
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
    /// @dev EIP-170 size-split: the checkpoint + §9 unified fee-routing + share-price-emit body lives
    ///      in VaultFees (separate bytecode, delegatecalled). Wrapper preserves the internal signature
    ///      + all ~9 call sites; behavior (INV-3 skim, routing, events) is byte-identical.
    function _checkpoint(PoolId id, uint8 t)
        internal
        returns (uint256 fee0, uint256 fee1, uint256 perfFee0, uint256 perfFee1)
    {
        return VaultFees.checkpoint(tranches[id][t], pools[id], _vaultCtx(id, t), revenueDistributor, anchorStaking);
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

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // BASE + LIMIT + IDLE — the ONLY strategy (contracts/VAULT_STRATEGY_V3.md). v3.4: `rebalanceLimit`,
    // `rebalanceBase`, `selfSwap`, `rebalanceViaVenue` (and the RWA defenses) are KEEPER-ONLY — every
    // safety bound is STILL re-verified on-chain (they now guard keeper mistakes/compromise). Only the
    // idempotent, nothing-moving `pokeOutOfRange` stays permissionless. `configureTier`/
    // `setVenueAllowed` stay owner-gated (trust/governance decisions).
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
    ) external nonReentrant returns (PoolId id) {
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
        // dependency at all, so no registry check applies (item 2 of the decided spec). v3.5 FIX
        // (audit finding, low): MEME previously stored/forwarded whatever `oracleFeed` the caller
        // supplied, unvalidated — inert today (MEME's fee/strategy paths never read it), but a latent
        // surface if a future code path ever consulted it without also re-checking the regime. Force
        // it to address(0) for MEME so "no oracle dependency" is actually true on-chain, not just
        // true by convention.
        address feedToSet = oracleFeed;
        if (regime == FeraTypes.Regime.RWA) {
            if (oracleFeed == address(0) || !approvedRwaFeeds[oracleFeed]) revert RwaFeedNotApproved();
        } else {
            feedToSet = address(0);
        }

        hook.registerRegime(key, regime);
        hook.setOracleFeed(id, feedToSet);
        poolManager.initialize(key, sqrtPriceX96);

        p.key = key;
        p.regime = regime;
        p.oracleFeed = feedToSet;
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

    /// @notice Governance throttle on keeper-only swaps (seconds; 0 = off, the default). A pure
    ///         defense-in-depth rate-limit against keeper-KEY compromise — bounds how fast a stolen key
    ///         could churn IL-realizing swaps. Every swap is independently bounded regardless.
    function setKeeperSwapInterval(uint32 intervalSeconds) external onlyOwner {
        keeperSwapInterval = intervalSeconds;
        emit KeeperSwapIntervalSet(intervalSeconds);
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
    function skimIdle(PoolId id, uint8 t) external onlyKeeper nonReentrant notPaused(id) knownTranche(id, t) keeperReady(id) {
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
    /// @dev KEEPER-ONLY (founder decision: even swap-free strategy actions carry a residual
    ///      timing-choice edge — an adversary picking WHEN a bounded action fires, cf. the F1
    ///      clock-starvation grief this codebase already patched once — so every position-MOVING
    ///      action is gated; zero grief surface beats bounded grief surface). All on-chain bounds
    ///      (min-interval, TWAP sanity) still verify — they now guard keeper mistakes/compromise.
    function rebalanceLimit(PoolId id, uint8 t) external onlyKeeper nonReentrant notPaused(id) knownTranche(id, t) keeperReady(id) {
        _requireBaseLimit(id, t);
        _requireRebalanceInterval(id, t); // R-15: bounded frequency (MEME shorter than RWA, both > 0)
        // Anti-whipsaw: never (re)deploy a limit onto a spot spike the TWAP disagrees with.
        if (_twapDeviationBps(id, FeraConstants.REBALANCE_TWAP_WINDOW_SEC) > FeraConstants.REBALANCE_TWAP_SANITY_BPS) {
            revert TwapOutOfBand();
        }
        _checkpoint(id, t);
        poolManager.unlock(abi.encode(CB_REBALANCE_LIMIT, id, t, bytes("")));
        // Finding-1 hardening: re-verify the SAME TWAP-sanity bound AFTER the callback returns. This
        // is a swap-free path (close -> spot read -> mint) with no other slippage check, so it is the
        // one place a mid-callback reentrant swap (see `keeperActive` NatSpec) could otherwise leave
        // spot manipulated at the moment of the fresh `getSlot0()` read inside `cbRebalanceLimit`. By
        // the time `unlock()` returns, `Lock.sol`'s global flag is closed again — any such manipulation
        // is already reflected in spot, and reverting here unwinds the ENTIRE transaction, including
        // whatever the reentrant call attempted to extract.
        if (_twapDeviationBps(id, FeraConstants.REBALANCE_TWAP_WINDOW_SEC) > FeraConstants.REBALANCE_TWAP_SANITY_BPS) {
            revert TwapOutOfBand();
        }
        lastRebalanceTs[id][t] = uint64(block.timestamp);
        emit StrategyAction(PoolId.unwrap(id), uint8(FeraTypes.StrategyKind.LimitDeploy), 0, 0, 0, bytes32(0));
    }

    /// @inheritdoc IFeraVault
    /// @dev KEEPER-ONLY for BOTH modes (founder decision — see rebalanceLimit). Gate 1-4 are
    ///      unchanged from v2; Gate 5 (execution slippage) is a
    ///      DIFFERENT bound from the NEW IL-budget cap (item 4 / FeraConstants.MAX_IL_BPS_PER_RECENTER):
    ///      Gate 5 bounds price-impact RATIO vs TWAP; the IL cap bounds the ABSOLUTE NAV-fraction any
    ///      one call's self-swap may put at risk. When the ideal rebalancing swap exceeds the IL
    ///      budget, `_cbRebalanceBase` clamps it (partial execution) instead of reverting — the base
    ///      band is still fully re-anchored (re-ticking alone realizes no IL, only a swap's price
    ///      impact does); the leftover imbalance is completed by a LATER call once the min-interval
    ///      has re-elapsed (via another `rebalanceBase`, a standalone `selfSwap`, or the swap-free
    ///      `rebalanceLimit`).
    function rebalanceBase(PoolId id, uint8 t, bool useSelfSwap) external onlyKeeper nonReentrant notPaused(id) knownTranche(id, t) keeperReady(id) {
        _requireBaseLimit(id, t);
        // EIP-170 size-split: gate + recenter body in VaultActions (delegatecalled). Every gate,
        // the IL-budget cap, Gate-5 slippage bound, both clocks + StrategyAction are byte-identical.
        VaultActions.rebalanceBase(
            tranches[id][t],
            pools[id],
            _vaultCtx(id, t),
            useSelfSwap,
            revenueDistributor,
            anchorStaking,
            oorSince[id],
            lastBaseRecenterTs[id],
            lastRebalanceTs[id]
        );
        // Finding-1 hardening: Gate 5 inside VaultActions compares spot-vBefore vs spot-vAfter, BOTH
        // read within the same callback — an attacker who reenters mid-callback controls the very
        // spot price vAfter is measured against, so a manipulated round-trip could still pass Gate 5.
        // Anchoring this second, independent check to the TWAP (not spot) closes that gap: it reverts
        // the whole transaction if the pool's post-recenter spot has drifted from its own TWAP, no
        // matter what Gate 5 concluded.
        if (_twapDeviationBps(id, FeraConstants.REBALANCE_TWAP_WINDOW_SEC) > FeraConstants.REBALANCE_TWAP_SANITY_BPS) {
            revert TwapOutOfBand();
        }
    }

    /// @notice Standalone bounded self-swap against the OWN v4 pool (ratio balancing). Executed output
    ///         re-verified ≥ (1 − MAX_REBALANCE_SLIPPAGE_BPS) × pool-TWAP-implied, else reverts. Spends
    ///         only the tranche's OWN reserve (no cross-tranche transfer). KEEPER-ONLY (swap path —
    ///         sandwich-surface reduction: no random caller can drive a swap), and additionally
    ///         bounded by the SAME per-call IL-budget notional cap `rebalanceBase` uses
    ///         (closes the loophole where a standalone call could otherwise finish, in one shot, what
    ///         a partial guarded recenter deliberately left capped) — a user-supplied `amountIn` over
    ///         budget REVERTS (`IlBudgetExceeded`) rather than being silently truncated.
    function selfSwap(PoolId id, uint8 t, bool zeroForOne, uint256 amountIn)
        external
        onlyKeeper
        nonReentrant
        notPaused(id)
        knownTranche(id, t)
        keeperReady(id)
        returns (uint256 amountOut)
    {
        _requireBaseLimit(id, t);
        // EIP-170 size-split: interval gate, reserve/IL-budget bounds, swap + clock + StrategyAction
        // live in VaultActions (delegatecalled) — byte-identical.
        return VaultActions.selfSwap(tranches[id][t], _vaultCtx(id, t), zeroForOne, amountIn, keeperSwapInterval, lastRebalanceTs[id]);
    }

    /// @inheritdoc IFeraVault
    /// @dev KEEPER-ONLY (swap path). TWO safety boundaries: the venue allowlist (governance/trust
    ///      decision) AND the keeper gate — only the keeper may TRIGGER a swap through an
    ///      ALREADY-WHITELISTED venue, bounded by the same on-chain TWAP-slippage check as self-swap.
    function rebalanceViaVenue(PoolId id, uint8 t, address venue, bool zeroForOne, uint256 amountIn)
        external
        onlyKeeper
        nonReentrant
        notPaused(id)
        knownTranche(id, t)
        keeperReady(id)
        returns (uint256 amountOut)
    {
        _requireBaseLimit(id, t);
        if (!rebalanceVenueAllowed[venue]) revert VenueNotAllowed();
        // EIP-170 size-split: interval gate, TWAP bound, bounded untrusted-venue call + balance-delta
        // reserve accounting + clock + StrategyAction live in VaultActions (delegatecalled).
        return VaultActions.rebalanceViaVenue(
            tranches[id][t], pools[id], _vaultCtx(id, t), venue, zeroForOne, amountIn, keeperSwapInterval, lastRebalanceTs[id]
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // v3-HARDENING (§5.1) — RWA REGIME-APPROPRIATE DEFENSES (RESTORED on base+limit+idle).
    // RWA prices MEAN-REVERT to the underlying real stock (unlike a memecoin), so the correct
    // posture is the OPPOSITE of MEME: in-hours we recenter TOWARD the oracle when the pool drifts;
    // off-hours / during an event window we batten down (widen + partial-withdraw). Both are
    // KEEPER-ONLY (v3.4 — every bound still re-verified on-chain), RWA-only, swap-free (band<->reserve
    // ⇒ zero IL by construction), and gated by the dedicated slow base-recenter clock (§5.1).
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice RWA IN-HOURS oracle-anchored base recenter. When the pool price has drifted past
    ///         `RWA_ORACLE_RECENTER_HYSTERESIS_BPS` from the Chainlink oracle DURING market hours (and
    ///         the drift is TWAP-confirmed, not a spot spike), re-anchor the base band TOWARD the
    ///         oracle price — RWA mean-reverts to the real stock, so providing liquidity at the true
    ///         price is correct (the OPPOSITE of MEME, where chasing the price loses money). Swap-free
    ///         (close base -> reserve -> re-mint around the oracle tick), so it realises ZERO IL and
    ///         value is conserved (Gate-5-style guard). KEEPER-ONLY (v3.4); every bound is on-chain.
    function rebalanceRwaOracle(PoolId id, uint8 t) external onlyKeeper nonReentrant notPaused(id) knownTranche(id, t) keeperReady(id) {
        // EIP-170 size-split: body in VaultRwa (separate bytecode, delegatecalled). Gates, swap-free
        // value-conservation bound, dedicated base-recenter clock + StrategyAction are byte-identical.
        VaultRwa.rebalanceRwaOracle(
            tranches[id][t],
            pools[id],
            tierConfig[id][t],
            _vaultCtx(id, t),
            revenueDistributor,
            anchorStaking,
            lastBaseRecenterTs[id],
            lastRebalanceTs[id]
        );
        // Finding-1 hardening (same rationale as rebalanceBase): re-anchor the post-recenter spot to
        // the manipulation-resistant TWAP, independent of whatever VaultRwa's own spot-vs-spot check
        // concluded.
        if (_twapDeviationBps(id, FeraConstants.REBALANCE_TWAP_WINDOW_SEC) > FeraConstants.REBALANCE_TWAP_SANITY_BPS) {
            revert TwapOutOfBand();
        }
    }

    /// @notice RWA OFF-HOURS / EVENT-WINDOW defensive posture. When the market is CLOSED (per the
    ///         on-chain hours/holiday/schedule gate) OR a scheduled-event window (earnings) is flagged,
    ///         WIDEN the base band AND PARTIAL-WITHDRAW a fraction (`RWA_OFFHOURS_WITHDRAW_FRAC_BPS`)
    ///         into idle reserve — so weekend drift + a Monday open gap cannot realise IL into a tight,
    ///         stale-priced band, and a fraction sits instantly-withdrawable in reserve. Swap-free
    ///         (band<->reserve only), value-conserving. RE-WIRES the previously-vestigial `eventWindow`
    ///         (OD-4). KEEPER-ONLY (v3.4); RWA-only; gated by the dedicated slow base-recenter clock.
    function defendRwaOffHours(PoolId id, uint8 t) external onlyKeeper nonReentrant notPaused(id) knownTranche(id, t) keeperReady(id) {
        // EIP-170 size-split: body in VaultRwa (separate bytecode, delegatecalled). Gates, swap-free
        // value-conservation bound, dedicated base-recenter clock + StrategyAction are byte-identical.
        VaultRwa.defendRwaOffHours(
            tranches[id][t],
            pools[id],
            tierConfig[id][t],
            _vaultCtx(id, t),
            revenueDistributor,
            anchorStaking,
            lastBaseRecenterTs[id],
            lastRebalanceTs[id]
        );
        // Finding-1 hardening (same rationale as rebalanceBase).
        if (_twapDeviationBps(id, FeraConstants.REBALANCE_TWAP_WINDOW_SEC) > FeraConstants.REBALANCE_TWAP_SANITY_BPS) {
            revert TwapOutOfBand();
        }
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
    /// @dev Team-curation gate for the AUTOMATED KEEPER (see `keeperActive` NatSpec). Never affects
    ///      deposits, withdrawals, or swaps — only `onlyKeeper` rebalance/skim actions consult it.
    function setKeeperActive(PoolId id, bool active) external onlyOwner {
        _setKeeperActive(id, active);
    }

    /// @inheritdoc IFeraVault
    /// @dev v3.5 hardening addendum (audit finding, medium: a forgotten per-pool `setKeeperActive`
    ///      call is silent and indistinguishable from a healthy idle pool). Same onlyOwner/
    ///      UnknownPool semantics as the single-pool setter — just batched, so the team can activate
    ///      (or deactivate) every pool from one redeploy/permissionless-creation wave in ONE tx
    ///      instead of one per pool. Still emits one `KeeperActiveSet` per pool (unchanged event
    ///      shape for indexers); reverts the WHOLE batch on the first unknown id (fail-closed, no
    ///      partial activation) exactly like the single-pool setter would on that id alone.
    function setKeeperActiveBatch(PoolId[] calldata ids, bool active) external onlyOwner {
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; ++i) {
            _setKeeperActive(ids[i], active);
        }
    }

    function _setKeeperActive(PoolId id, bool active) internal {
        if (!pools[id].initialized) revert UnknownPool();
        keeperActive[id] = active;
        emit KeeperActiveSet(PoolId.unwrap(id), active);
    }

    /// @inheritdoc IFeraVault
    /// @dev v3.5 hardening addendum (audit finding, medium): off-chain, discovering "which pools are
    ///      NOT keeper-active" otherwise means reconstructing the candidate id list from FeraHook's
    ///      `PoolRegistered` events (already how `backend/keepers/vaultStrategy.ts` discovers pools)
    ///      and then polling the public `keeperActive(id)` getter one id at a time. This lets a
    ///      monitoring/ops script pass that WHOLE candidate list in a single call and get back
    ///      exactly the subset still gated — one round-trip instead of N. Pure filter over the
    ///      existing mapping; adds no new storage and has no on-chain effect of its own. Passing an
    ///      id that was never `createBaseLimitPool`-initialized reports it as "inactive" too (the
    ///      mapping defaults false for any key) — callers are expected to source `ids` from
    ///      `PoolRegistered`, i.e. real pools only.
    function inactiveKeeperPools(PoolId[] calldata ids) external view returns (PoolId[] memory inactive) {
        uint256 len = ids.length;
        PoolId[] memory buf = new PoolId[](len);
        uint256 n;
        for (uint256 i = 0; i < len; ++i) {
            if (!keeperActive[ids[i]]) {
                buf[n++] = ids[i];
            }
        }
        inactive = new PoolId[](n);
        for (uint256 i = 0; i < n; ++i) {
            inactive[i] = buf[i];
        }
    }

    /// @inheritdoc IFeraVault
    function setCooldownExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        cooldownExempt[account] = exempt;
        emit CooldownExemptSet(account, exempt);
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
        // EIP-170 size-split: cooldown, tokenOut validation, checkpoint, pro-rata held debit, burn,
        // single-coin callback, minOut check + WithdrawSingle emit live in VaultActions (delegatecalled;
        // `msg.sender` preserved). Byte-identical to the pre-split inline path.
        return VaultActions.withdrawSingle(
            tranches[id][t],
            pools[id],
            _vaultCtx(id, t),
            shares,
            tokenOut,
            minOut,
            revenueDistributor,
            anchorStaking,
            lastDepositTs[id][t],
            cooldownExempt
        );
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

    /// @dev Finding-2 hardening: the shortest a `cooldownExempt` address may wait past its OWN last
    ///      deposit before withdrawing — its regime's JIT-forfeiture window plus a fixed safety
    ///      margin (see EXEMPT_WITHDRAW_MARGIN_SEC NatSpec), always well under DEPOSIT_COOLDOWN_SEC.
    ///      Audit finding (Low): delegates to the SHARED `VaultMath.exemptWithdrawFloorSec` — the
    ///      single source of truth also called directly by `VaultActions.withdrawSingle` — instead of
    ///      reimplementing the regime/JIT-window lookup here, so the two withdrawal paths cannot
    ///      silently drift apart if the JIT windows or margin constant are ever revisited.
    function _exemptWithdrawFloorSec(PoolId id) internal view returns (uint32) {
        return VaultMath.exemptWithdrawFloorSec(pools[id].regime);
    }

    /// @dev Generic min-interval guard against an arbitrary last-action timestamp (R-15).
    function _requireIntervalSince(uint64 last, uint32 minInterval) internal view {
        if (last != 0 && block.timestamp - last < minInterval) revert RebalanceTooSoon();
    }

    function _requireRebalanceInterval(PoolId id, uint8 t) internal view {
        _requireIntervalSince(lastRebalanceTs[id][t], _minRebalanceInterval(id));
    }

    // EIP-170 size-split: the base-range / TWAP-confirm / TWAP-implied-out bodies live in VaultMath
    // (separate bytecode, delegatecalled). These thin wrappers preserve the internal signatures + all
    // call sites; behavior is byte-identical (see VaultMath).
    function _baseOutOfRange(PoolId id, uint8 t) internal view returns (bool) {
        return VaultMath.baseOutOfRange(tranches[id][t], _vaultCtx(id, t));
    }

    // ── EXTERNAL PRICING (ERC-4626-style read surface, for DefiLlama / Rabby) ────────────────────
    /// @notice Manipulation-resistant NAV of a tranche in its QUOTE token, TWAP-priced. This is the
    ///         clean EXTERNAL number the share token's convertToAssets/pricePerShare read; it is NOT
    ///         the internal mint/redeem basis (that stays spot + 1h-cooldown-guarded). Covers base +
    ///         limit bands + pending + idle reserve, valued at the DEPOSIT_TWAP_WINDOW_SEC average.
    function quoteNav(PoolId id, uint8 t) public view knownTranche(id, t) returns (uint256) {
        return VaultMath.trancheValueAtTwapQuote(
            tranches[id][t], _vaultCtx(id, t), pools[id].quoteIsToken0, FeraConstants.DEPOSIT_TWAP_WINDOW_SEC
        );
    }

    /// @notice The pool's liquid QUOTE token — the unit quoteNav (and share pricing) is denominated in.
    function quoteAsset(PoolId id) public view returns (address) {
        PoolInfo storage p = pools[id];
        return p.quoteIsToken0 ? Currency.unwrap(p.key.currency0) : Currency.unwrap(p.key.currency1);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // v3 §2 — VOL-ADAPTIVE POSITION SIZING. Read the MEME EWMA the dynamic fee already reads (via
    // the hook's view); NEVER re-estimate it here.
    //
    // LVR RATIONALE (v3-hardening §5.1 — Milionis et al. "AMM and Loss-Versus-Rebalancing"; Bunni/
    // am-AMM; concentrated-liquidity LP studies). Recentering a TRENDING asset REALIZES the loss —
    // recentering literally *is* the "R" in loss-versus-rebalancing. A memecoin trends (it does not
    // mean-revert), so ACTIVELY recentering its base is a provably losing move, not a cadence to tune.
    // The MEME design is therefore WIDE-BASE-HOLD: this multiplier makes a high-realized-vol MEME base
    // approach FULL RANGE (see FeraConstants VOL_WIDTH_MULT_* — 25x default / 50x legal) so the base
    // stays IN RANGE through big moves and essentially NEVER needs recentering; the volatility-scaled
    // dynamic fee is the LVR compensation; near-spot capital efficiency is supplied by the NARROW
    // LIMIT, rebalanced by FLOW (swap-free `rebalanceLimit`), never by forced recenters. The MEME base
    // recenter (`rebalanceBase`) is retained ONLY as an opportunistic, IL-capped (§4), rate-limited
    // (6h dedicated interval, §5.1) safety valve for the rare case an extreme sustained move still
    // exits the wide base — it is NOT an every-N-minutes active loop. CRITICALLY, operability is
    // DECOUPLED from rebalancing: `deposit`/`withdraw`/`withdrawSingle` never depend on the base being
    // in range or on any rebalance succeeding — an out-of-range withdrawal simply returns the user's
    // fair pro-rata of current (possibly one-sided) holdings IN-KIND (INV-11). RWA is the OPPOSITE
    // (mean-reverts to the oracle → recenter TOWARD the oracle, §5.1) and stays at 1x.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @dev width = tierHalf × f(σ), clamped to the governance-set [min,max] multiplier band
    ///      (FeeLogic.widthMultiplierBps — same formula the MEME fee curve's σ-ramp mirrors). For a
    ///      volatile MEME pair f(σ) is large ⇒ a near-full-range hold-in-place base (LVR: do not chase
    ///      the trend). RWA has no EWMA-vol signal wired in the hook (its dynamic fee uses oracle
    ///      deviation, not an EWMA) — multiplier fixed at 1x for RWA (it is recentered toward the
    ///      oracle instead, §5.1).
    function _effectiveHalfWidth(PoolId id, int24 tierHalf) internal view returns (int24) {
        return VaultMath.effectiveHalfWidth(pools[id], _vaultCtx(id, 0), tierHalf);
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

    /// @dev Non-reverting Chainlink read (unlike the legacy strict oracle gate this replaces): the
    ///      skew bias degrades to pure-inventory (never reverts the rebalance) on a stale/absent/
    ///      malformed feed — matching the "never revert a mechanical action for an oracle hiccup"
    ///      discipline the fee overlay already follows.

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

    /// @dev |spot − TWAP(window)| in bps of the TWAP (VaultMath — same-block manipulation trips it).
    function _twapDeviationBps(PoolId id, uint32 window) internal view returns (uint256) {
        return VaultMath.twapDeviationBps(_vaultCtx(id, 0), window);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // v4 unlock callback — the ONLY place liquidity is mutated (flash accounting). Every action
    // is scoped to ONE tranche's bands via the tranche-scoped salt (INV-15 / D-18).
    // ═══════════════════════════════════════════════════════════════════════════════════════

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyKeeper();
        (uint8 action, PoolId id, uint8 t, bytes memory payload) = abi.decode(data, (uint8, PoolId, uint8, bytes));

        // EIP-170 size-split: the heavy flash-accounting bodies live in VaultOps (separate bytecode,
        // delegatecalled). `_vaultCtx` threads this contract's immutables + the vol-width clamp bounds;
        // the storage struct refs let VaultOps read/write the vault's own state in place.
        VaultOps.Ctx memory c = _vaultCtx(id, t);
        TrancheState storage tr = tranches[id][t];
        PoolInfo storage p = pools[id];

        if (action == CB_CHECKPOINT) return VaultOps.cbCheckpoint(tr, p, c);
        if (action == CB_FIRST_DEPOSIT) return VaultOps.cbFirstDeposit(tr, p, c, payload);
        if (action == CB_DEPOSIT) return VaultOps.cbDeposit(tr, p, c, payload);
        if (action == CB_WITHDRAW) return VaultOps.cbWithdraw(tr, p, c, payload);
        if (action == CB_SKIM_IDLE) return VaultOps.cbSkimIdle(tr, p, c, payload);
        if (action == CB_REBALANCE_LIMIT) return VaultOps.cbRebalanceLimit(tr, p, tierConfig[id][t], c);
        if (action == CB_REBALANCE_BASE) return VaultOps.cbRebalanceBase(tr, p, tierConfig[id][t], c, payload);
        if (action == CB_SELF_SWAP) return VaultOps.cbSelfSwap(tr, p, c, payload);
        if (action == CB_WITHDRAW_SINGLE) return VaultOps.cbWithdrawSingle(tr, p, c, payload);
        if (action == CB_ROUTE_FEE_SWAP) return VaultOps.cbRouteFeeSwap(p, c, payload);
        if (action == CB_RWA_ORACLE_RECENTER) return VaultOps.cbRwaOracleRecenter(tr, p, tierConfig[id][t], c, payload);
        return VaultOps.cbRwaDefend(tr, p, tierConfig[id][t], c); // CB_RWA_DEFEND
    }

    /// @dev Assemble the VaultOps call context from this contract's immutables + governance bounds.
    function _vaultCtx(PoolId id, uint8 t) internal view returns (VaultOps.Ctx memory) {
        return VaultOps.Ctx({pm: poolManager, hook: hook, id: id, t: t, volMin: volWidthMultMinBps, volMax: volWidthMultMaxBps});
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Valuation / tick helpers
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @dev Tranche value in token1 terms at spot (bands + pending + reserves), plus spot context
    ///      (VaultMath — separate bytecode). Wrapper preserves the internal signature + call sites.
    function _trancheValue(PoolId id, uint8 t) internal view returns (uint256 v, uint160 sqrtPriceX96, int24 tick) {
        return VaultMath.trancheValue(tranches[id][t], _vaultCtx(id, t));
    }

    function _valueInToken1(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        return FullMath.mulDiv(amount0, priceX96, 1 << 96) + amount1;
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
            t,
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
    /// @dev Audit finding (Low): this and the two setters below are `onlyKeeper` but move no funds
    ///      and never call `_modifyBand`, so they were originally left off `keeperReady` on the
    ///      theory that they're flags, not "pool-touching" in Finding-1's reentrancy sense. But
    ///      `setMarketOpen`/`setHoliday` mirror straight onto `FeraHook`'s RWA in-hours/off-hours fee
    ///      overlay — a real pricing lever — so leaving them ungated let a keeper flip RWA market
    ///      regime on a pool the owner never reviewed/activated, contradicting `keeperActive`'s
    ///      documented promise that "the keeper cannot touch an unreviewed pool at all." Gating all
    ///      three with `keeperReady` closes that gap and makes the modifier's own claim ("blocks
    ///      EVERY onlyKeeper ... action") literally true again.
    function setMarketOpen(PoolId id, bool open) external onlyKeeper keeperReady(id) {
        pools[id].marketOpen = open;
        hook.setMarketOpen(id, open);
    }

    /// @notice Keeper flags a scheduled-event session (earnings before next open — D-M11 legacy;
    ///         reserved, no on-chain consumer in v3).
    function setEventWindow(PoolId id, bool on) external onlyKeeper keeperReady(id) {
        pools[id].eventWindow = on;
    }

    /// @notice Keeper holiday flag (§10) — force-closes an RWA market regardless of the calendar or
    ///         the hours flag. Fail-static: a keeper can only CLOSE the market with this, never open.
    function setHoliday(PoolId id, bool on) external onlyKeeper keeperReady(id) {
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
