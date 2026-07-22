// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IFeraIndexVault} from "./interfaces/IFeraIndexVault.sol";
import {IFeraVault} from "./interfaces/IFeraVault.sol";
import {IFeraShare} from "./interfaces/IFeraShare.sol";
import {IFeraHook} from "./interfaces/IFeraHook.sol";
import {FeraTypes} from "./libraries/FeraTypes.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal view into the FeraVault's TWAP-priced NAV accounting. `quoteNav` is `public` on the
///      concrete FeraVault but intentionally NOT part of `IFeraVault` (it is a DefiLlama/Rabby read
///      surface); the index declares this narrow interface rather than widening `IFeraVault` — the
///      same pattern `FeraShare`'s `IVaultShareOracle` uses. `PoolId` is `type PoolId is bytes32`, so
///      the selector matches the concrete vault's `quoteNav(PoolId,uint8)`.
interface IFeraVaultNav {
    function quoteNav(PoolId id, uint8 tranche) external view returns (uint256);
}

/// @title FeraIndexVault (fIDX) — the FERA memecoin-LP index
/// @notice "One deposit → a diversified basket of FERA LP positions." An ERC-4626-STYLE single-asset
///         vault (asset = wWETH). A deposit atomically: (1) for each allowlisted member pool, swaps a
///         slice of wWETH → that memecoin THROUGH the member's own FERA v4 pool (never an external
///         router — the exact `poolManager.unlock`/`swap` pattern FeraVault.selfSwap uses), (2)
///         deposits both legs into the pool's tranche-0 ("Steady") position via `FeraVault.deposit`,
///         and (3) mints fIDX shares by the TWAP-priced NAV delta. Withdrawal reverses it
///         proportionally; `emergencyRedeemInKind` is the swap-free safety valve.
///
/// @dev THIN BY DESIGN (spec §8.4): the index adds NO new price oracle. NAV and every swap `minOut`
///      are anchored to the FeraVault's/hook's existing, manipulation-resistant TWAP accounting:
///        - NAV  : `Σ_i FeraVault.quoteNav(id_i, 0) × bal_i / totalSupply_i  +  idle wWETH`.
///        - minOut: `hook`-TWAP-implied output, haircut by the live dynamic fee + a tight slippage
///          tolerance (`MAX_ENTRY_SLIPPAGE_BPS`), so a same-block price push cannot cheat the fill.
///      The index holds NO privileged role in FeraVault — it is a plain LP/swapper. Rounding is
///      ALWAYS against the depositor (min(dNAV, paid) mint; floored proportional redeem), so a
///      no-trade round trip can never return more than was deposited (INV-I1).
///
/// @dev ⚠️ COOLDOWN COUPLING (top auditor risk — see report): `FeraVault` keys its 1h anti-flash-loan
///      cooldown (and share transfer-lock) by the DEPOSITING address — here, this index. Every index
///      deposit (and rebalance, which deposits) therefore re-arms the index's OWN cooldown across
///      ALL members, blocking `withdraw` (vault-cooldown) AND `emergencyRedeemInKind` (transfer-lock)
///      for `DEPOSIT_COOLDOWN_SEC`. Aged holdings redeem freely (INV-I5); a stream of fresh deposits
///      is a liveness/griefing vector a v2 vault change (index-exempt cooldown) should close.
contract FeraIndexVault is IFeraIndexVault, IUnlockCallback, ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    // ── Immutable wiring ───────────────────────────────────────────────────────────────────────
    /// @notice The ERC-4626 underlying asset — wWETH (the single token in/out). v1 members are all
    ///         wWETH-quoted; USDG-quoted pools are excluded (OD-1) so NAV stays single-quote.
    address public immutable asset;
    IPoolManager public immutable poolManager;
    IFeraHook public immutable hook;
    IFeraVault public immutable feraVault;
    address public keeper;

    /// @dev The index only ever touches tranche 0 (Steady) of each member pool (spec §1/§3).
    uint8 internal constant TRANCHE = 0;

    // ── Guardrail constants (spec §6). All PROVISIONAL values are flagged; changing them is a
    //    re-audit item. They live in code (the "Gamma lesson"): no setter can loosen them. ─────────
    uint256 internal constant BPS = 10_000;
    /// @dev Locked forever on the first deposit to defuse the ERC-4626 share-inflation attack (R-12),
    ///      mirroring FeraVault's MINIMUM_LIQUIDITY burn.
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant MAX_MEMBERS = 12; // spec §5/§8.5 — cap entry gas
    uint256 internal constant MAX_WEIGHT_BPS = 3_000; // spec §6 — no member > 30%
    uint256 internal constant MIN_WEIGHT_BPS = 500; // spec §6 — a listed member is ≥ 5% (or dropped)

    // DESIGN: swap `minOut` is anchored to the hook TWAP (manipulation-resistant) and haircut by the
    // LIVE dynamic fee (read per-swap via `hook.getDynamicFee`) SEPARATELY from this pure-slippage
    // tolerance. Separating the known fee from the adversarial slippage keeps the anti-sandwich bound
    // (INV-I4) tight (~1%) regardless of the fee regime, instead of a loose fixed haircut that would
    // have to swallow the 0.34%–3% MEME fee band. The alternative (fee-blind fixed tolerance) was
    // rejected as it makes the sandwich bound meaninglessly wide during high-vol fee regimes.
    /// @dev Pure slippage tolerance applied ON TOP of the live dynamic fee. Matches the vault's own
    ///      MAX_REBALANCE_SLIPPAGE_BPS discipline.
    uint256 internal constant MAX_ENTRY_SLIPPAGE_BPS = 100; // 1% [PROVISIONAL]
    /// @dev Max spot-price move a SINGLE entry/exit swap may cause — the "size vs pool depth" cap
    ///      (spec §6 MAX_ENTRY_VS_DEPTH_BPS). Kept strictly below the vault's 2% deposit TWAP gate so
    ///      a swap the index accepts never trips the subsequent `FeraVault.deposit` gate.
    uint256 internal constant MAX_ENTRY_VS_DEPTH_BPS = 150; // 1.5% [PROVISIONAL]
    /// @dev Conservative upper bound on the MEME sell-side fee adder (mirrors
    ///      FeraConstants.MEME_SELL_ADDER_K_PIPS = 20000 pips = 2%), added to the fee haircut on
    ///      memecoin→wWETH swaps so a legitimate sell never spuriously reverts. Loosens the EXIT
    ///      minOut bound; the tight exit bound is the depth cap above (see report / DESIGN note).
    uint256 internal constant SELL_SURCHARGE_CUSHION_BPS = 200;

    uint256 internal constant REBALANCE_BAND_BPS = 2_000; // spec §6 — drift band that justifies a move
    uint256 internal constant MAX_REBALANCE_STEP_BPS = 500; // 5% of NAV per call [PROVISIONAL]
    uint32 internal constant REBALANCE_COOLDOWN_SEC = 3_600; // 1h between rebalances [PROVISIONAL]

    /// @dev Manipulation-resistant TWAP window for swap `minOut` bounds — the vault's own
    ///      REBALANCE_TWAP_WINDOW_SEC (1800s). NAV uses the vault's internal DEPOSIT_TWAP_WINDOW.
    uint32 internal constant SWAP_TWAP_WINDOW_SEC = 1_800;
    /// @dev Fail-closed staleness bound on the newest TWAP observation (FeraConstants.TWAP_MAX_STALENESS_SEC).
    uint32 internal constant TWAP_MAX_STALENESS_SEC = 7_200;

    /// @dev Below this, a per-member wWETH allocation is skipped (avoids zero/dust swaps + deposits).
    uint256 internal constant MIN_MEMBER_ALLOC = 1e9;
    /// @dev Residual memecoin below this (post-deposit refund dust) is left un-swept — a negligible,
    ///      one-directional leak AWAY from index liability (it is NOT counted in NAV, so it can never
    ///      be extracted). Above it, the residual is swapped back to wWETH so the index never holds a
    ///      naked memecoin across the tx boundary (spec §3).
    uint256 internal constant DUST = 1e6;

    // ── Member set ─────────────────────────────────────────────────────────────────────────────
    struct Member {
        PoolKey key; // full v4 key (needed for `poolManager.swap`)
        address share; // tranche-0 FeraShare clone the index holds
        bool quoteIsToken0; // wWETH is currency0 in this pool
        uint16 weightBps; // target weight (bps of the basket)
        bool exists;
    }

    PoolId[] internal memberIds;
    mapping(PoolId => Member) internal memberOf;

    /// @notice Last successful `rebalance` timestamp (the REBALANCE_COOLDOWN_SEC clock).
    uint64 public lastRebalanceTs;

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }

    constructor(
        address asset_,
        IPoolManager poolManager_,
        IFeraHook hook_,
        IFeraVault feraVault_,
        address keeper_,
        address timelockOwner,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) Ownable(timelockOwner) {
        if (
            asset_ == address(0) || address(poolManager_) == address(0) || address(hook_) == address(0)
                || address(feraVault_) == address(0) || keeper_ == address(0)
        ) revert ZeroAddress();
        asset = asset_;
        poolManager = poolManager_;
        hook = hook_;
        feraVault = feraVault_;
        keeper = keeper_;
        // Approve the (trusted, immutable) vault to pull the quote leg on every member deposit.
        IERC20(asset_).forceApprove(address(feraVault_), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // Deposit — swap each memecoin leg IN through the member pool, deposit both legs, mint by NAV Δ
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraIndexVault
    function deposit(uint256 assets, uint256 minSharesOut) external nonReentrant returns (uint256 shares) {
        uint256 n = memberIds.length;
        if (n == 0) revert NoMembers();
        if (assets == 0) revert Slippage();

        // NAV BEFORE the incoming assets land (so the depositor's own wWETH is not double-counted).
        uint256 navBefore = _nav();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);

        // Deploy the incoming `assets` across the basket at target weights. Each member: swap half to
        // its memecoin (bounded), deposit both legs into tranche 0, sweep any memecoin refund back.
        for (uint256 i; i < n; ++i) {
            PoolId mid = memberIds[i];
            Member storage m = memberOf[mid];
            _deployMember(m, mid, FullMath.mulDiv(assets, m.weightBps, BPS));
        }

        uint256 navAfter = _nav();
        // DESIGN: shares are priced by min(dNAV, paid) at the vault's TWAP-priced NAV — the same
        // rounding discipline as FeraVault._mintNonFirst — with a MINIMUM_LIQUIDITY burn on the first
        // deposit. The index adds NO new oracle (spec §8.4): NAV is Σ member quoteNav-per-share × held
        // + idle wWETH. This guarantees a no-trade round trip never returns more than deposited (INV-I1)
        // and a same-block price push cannot over-mint at existing holders' expense (INV-I4).
        // dNAV = the TWAP-value the basket gained (+ any wWETH left idle). By construction ≤ paid
        // (entry fee + impact only ever LOSE value); the min() is REC-10 belt-and-suspenders so a
        // TWAP-vs-spot basis swing can never over-mint at existing holders' expense.
        uint256 dNav = navAfter > navBefore ? navAfter - navBefore : 0;
        uint256 value = dNav < assets ? dNav : assets;

        uint256 supply = totalSupply();
        if (supply == 0) {
            require(value > MINIMUM_LIQUIDITY, "min-liq");
            shares = value - MINIMUM_LIQUIDITY;
            _mint(DEAD, MINIMUM_LIQUIDITY); // lock the first 1000 wei of shares forever (R-12)
        } else {
            if (navBefore == 0) revert NavZero();
            shares = FullMath.mulDiv(value, supply, navBefore); // round DOWN, against the depositor
        }
        if (shares == 0 || shares < minSharesOut) revert Slippage();

        _mint(msg.sender, shares);
        emit Deposit(msg.sender, assets, shares, navAfter);
    }

    /// @dev Acquire member `m`'s memecoin leg and add both legs to its tranche 0. All-or-nothing:
    ///      any swap slippage/depth breach, or the vault's deposit TWAP gate, reverts the whole tx.
    function _deployMember(Member storage m, PoolId poolId, uint256 alloc) internal {
        if (alloc < MIN_MEMBER_ALLOC) return; // skip a dust allocation (tiny-weight member)
        address meme = m.quoteIsToken0 ? Currency.unwrap(m.key.currency1) : Currency.unwrap(m.key.currency0);

        // DESIGN: acquire the memecoin leg by swapping HALF the allocation through the member's OWN
        // FERA pool (not an external router — spec §4), deposit both legs, then sweep any memecoin the
        // ratio-match refunds back to wWETH so the index never holds a naked memecoin across the tx
        // (spec §3). Fixed-half is the simplest correct choice; in a lopsided member pool it leaves a
        // larger memecoin refund and pays a second (bounded) swap — a v1.1 optimization is to size the
        // initial swap to the member's live band ratio. Correctness is unaffected either way.
        // 1. Swap half the allocation wWETH → memecoin THROUGH the member pool (TWAP + depth bounded).
        uint256 swapIn = alloc / 2;
        // zeroForOne == quoteIsToken0 ⇔ spend the quote (wWETH) side to receive the memecoin.
        uint256 memeOut = _swapThroughPool(m, poolId, m.quoteIsToken0, swapIn);

        // 2. Deposit both legs into tranche 0. Amounts are in on-chain (currency0/1) order.
        uint256 quoteLeg = alloc - swapIn;
        (uint256 amount0, uint256 amount1) =
            m.quoteIsToken0 ? (quoteLeg, memeOut) : (memeOut, quoteLeg);
        // minShares 0: the index's own min(dNAV, paid) NAV cap + the outer minSharesOut are the real
        // guards; the per-leg mint amount is not independently meaningful.
        feraVault.deposit(poolId, TRANCHE, amount0, amount1, 0);

        // 3. Sweep any memecoin the ratio-match refunded back to wWETH (spec §3 — never hold a naked
        //    memecoin across the tx). Sequential per-member processing ⇒ this balance is m's residual.
        uint256 residual = IERC20(meme).balanceOf(address(this));
        if (residual > DUST) _swapThroughPool(m, poolId, !m.quoteIsToken0, residual);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // Withdraw (proportional) — redeem each member pro-rata, swap the memecoin legs back, pay wWETH
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraIndexVault
    function withdraw(uint256 shares, uint256 minAssetsOut) external nonReentrant returns (uint256 assets) {
        uint256 supply = totalSupply();
        if (shares == 0 || shares > balanceOf(msg.sender)) revert Slippage();

        // Pro-rata idle wWETH (round DOWN — dust stays with remaining holders, R-17).
        uint256 idleOut = FullMath.mulDiv(shares, IERC20(asset).balanceOf(address(this)), supply);

        _burn(msg.sender, shares); // CEI: burn before pulling liquidity

        uint256 got = idleOut;
        uint256 n = memberIds.length;
        for (uint256 i; i < n; ++i) {
            Member storage m = memberOf[memberIds[i]];
            uint256 shareOut = FullMath.mulDiv(shares, IERC20(m.share).balanceOf(address(this)), supply); // floor
            if (shareOut == 0) continue;
            // Two tokens out to the index (vault-cooldown-gated — reverts CooldownActive if the index
            // deposited into this member within DEPOSIT_COOLDOWN_SEC).
            (uint256 out0, uint256 out1) = feraVault.withdraw(memberIds[i], TRANCHE, shareOut, 0, 0);
            (uint256 quoteOut, uint256 memeOut) = m.quoteIsToken0 ? (out0, out1) : (out1, out0);
            got += quoteOut;
            if (memeOut > 0) got += _swapThroughPool(m, memberIds[i], !m.quoteIsToken0, memeOut); // memecoin → wWETH
        }

        assets = got;
        if (assets < minAssetsOut) revert Slippage();
        IERC20(asset).safeTransfer(msg.sender, assets);
        emit Withdraw(msg.sender, shares, assets);
    }

    /// @inheritdoc IFeraIndexVault
    function emergencyRedeemInKind(uint256 shares) external nonReentrant {
        uint256 supply = totalSupply();
        if (shares == 0 || shares > balanceOf(msg.sender)) revert Slippage();

        uint256 idleOut = FullMath.mulDiv(shares, IERC20(asset).balanceOf(address(this)), supply);
        uint256 n = memberIds.length;

        // Fail CLEARLY (spec §5) if inside the vault's share transfer-lock window — the raw
        // FeraShare.transfer would revert TransferLocked; we surface CooldownActive up front.
        for (uint256 i; i < n; ++i) {
            if (block.timestamp < IFeraShare(memberOf[memberIds[i]].share).transferLockUntil(address(this))) {
                revert CooldownActive();
            }
        }

        _burn(msg.sender, shares); // CEI

        for (uint256 i; i < n; ++i) {
            address share = memberOf[memberIds[i]].share;
            uint256 shareOut = FullMath.mulDiv(shares, IERC20(share).balanceOf(address(this)), supply);
            if (shareOut > 0) IERC20(share).safeTransfer(msg.sender, shareOut); // NO swap — always solvent for aged shares
        }
        if (idleOut > 0) IERC20(asset).safeTransfer(msg.sender, idleOut);
        emit EmergencyRedeem(msg.sender, shares);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // v4 unlock callback — the ONLY place the index touches poolManager liquidity/swaps
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev Executes ONE bounded exact-input swap against a member pool and resolves the deltas to
    ///      the index (settle the input side, take the output side) — the same flash-accounting
    ///      shape as `VaultOps._doSelfSwap`. `minOut` is computed by the caller off the hook TWAP.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 minOut) =
            abi.decode(data, (PoolKey, bool, uint256, uint256));

        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = poolManager.swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), ""
        );

        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        uint256 amountOut;
        if (a0 < 0) key.currency0.settle(poolManager, address(this), uint256(uint128(-a0)), false);
        else if (a0 > 0) {
            key.currency0.take(poolManager, address(this), uint256(uint128(a0)), false);
            amountOut = uint256(uint128(a0));
        }
        if (a1 < 0) key.currency1.settle(poolManager, address(this), uint256(uint128(-a1)), false);
        else if (a1 > 0) {
            key.currency1.take(poolManager, address(this), uint256(uint128(a1)), false);
            amountOut = uint256(uint128(a1));
        }
        if (amountOut < minOut) revert Slippage();
        return abi.encode(amountOut);
    }

    /// @dev Bound + execute a swap through member `m`'s pool. `minOut` is TWAP-implied and haircut by
    ///      the live dynamic fee (+ sell cushion) and MAX_ENTRY_SLIPPAGE_BPS; the realized spot move
    ///      is additionally capped at MAX_ENTRY_VS_DEPTH_BPS (size-vs-depth). Reverts on either breach.
    function _swapThroughPool(Member storage m, PoolId poolId, bool zeroForOne, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;
        (uint160 spotBefore,,,) = poolManager.getSlot0(poolId);
        uint256 minOut = _minOut(m, poolId, zeroForOne, amountIn);

        amountOut = abi.decode(poolManager.unlock(abi.encode(m.key, zeroForOne, amountIn, minOut)), (uint256));

        (uint160 spotAfter,,,) = poolManager.getSlot0(poolId);
        _requireDepthOk(spotBefore, spotAfter);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // Admin — member set + weights (timelock owner), all §6-guardrail-clamped
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraIndexVault
    function setMembers(PoolKey[] calldata keys, uint16[] calldata weightsBps) external onlyOwner {
        uint256 k = keys.length;
        if (k != weightsBps.length) revert LengthMismatch();
        if (k == 0 || k > MAX_MEMBERS) revert TooManyMembers();
        _requireWeights(weightsBps);

        // Compute the new id set + validate every key against the vault.
        PoolId[] memory newIds = new PoolId[](k);
        for (uint256 i; i < k; ++i) {
            PoolId id = keys[i].toId();
            for (uint256 j; j < i; ++j) {
                if (PoolId.unwrap(newIds[j]) == PoolId.unwrap(id)) revert DuplicateMember();
            }
            newIds[i] = id;
        }

        // DESIGN: setMembers is a full replacement; a currently-held member that is being DROPPED must
        // be fully divested first (index balance == 0) — otherwise its FeraShare would be orphaned
        // (uncounted in NAV, unredeemable) and strand value. The timelock rebalances a member to 0
        // before removing it.
        uint256 oldN = memberIds.length;
        for (uint256 i; i < oldN; ++i) {
            PoolId oldId = memberIds[i];
            bool kept;
            for (uint256 j; j < k; ++j) {
                if (PoolId.unwrap(newIds[j]) == PoolId.unwrap(oldId)) {
                    kept = true;
                    break;
                }
            }
            address oldShare = memberOf[oldId].share;
            if (!kept && oldShare != address(0) && IERC20(oldShare).balanceOf(address(this)) != 0) {
                revert MemberHasBalance();
            }
            delete memberOf[oldId];
        }

        // Rebuild the set.
        delete memberIds;
        bytes32[] memory ids = new bytes32[](k);
        for (uint256 i; i < k; ++i) {
            (address share, bool q0, address meme) = _validateMemberKey(keys[i], newIds[i]);
            memberOf[newIds[i]] =
                Member({key: keys[i], share: share, quoteIsToken0: q0, weightBps: weightsBps[i], exists: true});
            memberIds.push(newIds[i]);
            ids[i] = PoolId.unwrap(newIds[i]);
            IERC20(meme).forceApprove(address(feraVault), type(uint256).max); // vault pulls the memecoin leg on deposit
        }
        emit MembersUpdated(ids, weightsBps);
    }

    /// @inheritdoc IFeraIndexVault
    function setWeights(uint16[] calldata weightsBps) external onlyOwner {
        uint256 n = memberIds.length;
        if (n == 0) revert NoMembers();
        if (weightsBps.length != n) revert LengthMismatch();
        _requireWeights(weightsBps);
        for (uint256 i; i < n; ++i) {
            memberOf[memberIds[i]].weightBps = weightsBps[i];
        }
        emit WeightsUpdated(weightsBps);
    }

    /// @inheritdoc IFeraIndexVault
    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    /// @dev Enforce the §6 weight clamps: each in [MIN_WEIGHT_BPS, MAX_WEIGHT_BPS], Σ == 10_000.
    function _requireWeights(uint16[] calldata weightsBps) internal pure {
        uint256 sum;
        for (uint256 i; i < weightsBps.length; ++i) {
            uint16 w = weightsBps[i];
            if (w < MIN_WEIGHT_BPS || w > MAX_WEIGHT_BPS) revert BadWeight();
            sum += w;
        }
        if (sum != BPS) revert WeightSumNot100();
    }

    /// @dev Validate a candidate member key against the FeraVault: curated (tranche-0 share exists),
    ///      MEME regime, quote side is exactly wWETH, routed through the real FERA hook (so the TWAP
    ///      the index's `minOut` trusts is the manipulation-resistant one).
    function _validateMemberKey(PoolKey calldata key, PoolId id)
        internal
        view
        returns (address share, bool quoteIsToken0, address meme)
    {
        // DESIGN: v1 members are restricted to curated, MEME-regime, wWETH-quoted, real-hook pools.
        // MEME-only keeps the fee/sell-surcharge model correct; wWETH-only keeps NAV single-quote
        // (USDG excluded, OD-1); the real-hook check ensures the TWAP the index's minOut trusts is the
        // manipulation-resistant cumulative-tick one (a fake-hook pool would degrade it to spot).
        share = feraVault.shareToken(id, TRANCHE);
        if (share == address(0)) revert PoolNotCurated();
        if (feraVault.regimeOf(id) != FeraTypes.Regime.MEME) revert NotMemePool();
        if (address(key.hooks) != address(hook)) revert WrongHook();

        quoteIsToken0 = feraVault.quoteIsToken0(id);
        address quoteTok = quoteIsToken0 ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        if (quoteTok != asset) revert QuoteNotAsset();
        meme = quoteIsToken0 ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // Rebalance (keeper, bounded) — shift ≤ MAX_REBALANCE_STEP_BPS of NAV overweight → underweight
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraIndexVault
    function rebalance(PoolId from, PoolId to, uint256 navBps) external onlyKeeper nonReentrant {
        if (lastRebalanceTs != 0 && block.timestamp < lastRebalanceTs + REBALANCE_COOLDOWN_SEC) {
            revert RebalanceTooSoon();
        }
        if (navBps == 0 || navBps > MAX_REBALANCE_STEP_BPS) revert StepTooLarge();
        Member storage mf = memberOf[from];
        Member storage mt = memberOf[to];
        if (!mf.exists || !mt.exists) revert MemberNotFound();

        uint256 nav = _nav();
        if (nav == 0) revert NavZero();
        uint256 fromVal = _memberValueStorage(mf, from);
        uint256 toVal = _memberValueStorage(mt, to);

        // DESIGN: `from` must be drifted ABOVE its target by more than the band (spec §6: "drift >
        // REBALANCE_BAND_BPS"), and `to` must be below its target (an underweight recipient the move
        // actually helps). We do NOT require `to` to breach the band too — that would make a move
        // that is clearly corrective (a heavily overweight `from`) impossible whenever no single
        // recipient is ALSO 20% under, needlessly stranding the drift.
        if (fromVal * BPS <= (uint256(mf.weightBps) + REBALANCE_BAND_BPS) * nav) revert NotOverweight();
        if (toVal * BPS >= uint256(mt.weightBps) * nav) revert NotUnderweight();

        // Redeem `moveVal`-worth of `from` (never more than the whole position), swap its memecoin
        // leg back to wWETH, and deploy the proceeds into `to`. No shares minted/burned — value only
        // SHIFTS; the (bounded) swap/entry cost is borne pro-rata by all holders, never created.
        uint256 moveVal = FullMath.mulDiv(nav, navBps, BPS);
        uint256 fromBal = IERC20(mf.share).balanceOf(address(this));
        uint256 redeem = FullMath.mulDiv(fromBal, moveVal, fromVal);
        if (redeem > fromBal) redeem = fromBal;
        if (redeem == 0) revert Slippage();

        (uint256 out0, uint256 out1) = feraVault.withdraw(from, TRANCHE, redeem, 0, 0);
        (uint256 quoteOut, uint256 memeOut) = mf.quoteIsToken0 ? (out0, out1) : (out1, out0);
        uint256 wweth = quoteOut;
        if (memeOut > 0) wweth += _swapThroughPool(mf, from, !mf.quoteIsToken0, memeOut);

        _deployMember(mt, to, wweth);
        lastRebalanceTs = uint64(block.timestamp);
        emit Rebalance(PoolId.unwrap(from), PoolId.unwrap(to), moveVal);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // NAV + swap-bound math (all anchored to the vault/hook TWAP — the index adds no new oracle)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev Basket NAV in wWETH: Σ (member tranche-0 quoteNav × index's share fraction) + idle wWETH.
    function _nav() internal view returns (uint256 nav) {
        uint256 n = memberIds.length;
        for (uint256 i; i < n; ++i) {
            PoolId id = memberIds[i];
            Member storage m = memberOf[id];
            uint256 bal = IERC20(m.share).balanceOf(address(this));
            if (bal == 0) continue;
            uint256 ts = IERC20(m.share).totalSupply(); // > 0 since the index's own bal > 0
            nav += FullMath.mulDiv(IFeraVaultNav(address(feraVault)).quoteNav(id, TRANCHE), bal, ts);
        }
        nav += IERC20(asset).balanceOf(address(this));
    }

    function _memberValueStorage(Member storage m, PoolId poolId) internal view returns (uint256) {
        uint256 bal = IERC20(m.share).balanceOf(address(this));
        if (bal == 0) return 0;
        uint256 ts = IERC20(m.share).totalSupply();
        return FullMath.mulDiv(IFeraVaultNav(address(feraVault)).quoteNav(poolId, TRANCHE), bal, ts);
    }

    /// @dev TWAP-implied output haircut by (live dynamic fee + optional sell cushion + slippage tol).
    function _minOut(Member storage m, PoolId id, bool zeroForOne, uint256 amountIn) internal view returns (uint256) {
        uint256 implied = _twapImpliedOut(id, zeroForOne, amountIn);
        // sellingMeme == spending the memecoin side (memecoin→wWETH). MEME pools add a sell surcharge.
        bool sellingMeme = zeroForOne != m.quoteIsToken0;
        uint256 feeBps = uint256(hook.getDynamicFee(id)) / 100; // pips (1e6) → bps (1e4); never reverts
        uint256 haircut = feeBps + MAX_ENTRY_SLIPPAGE_BPS + (sellingMeme ? SELL_SURCHARGE_CUSHION_BPS : 0);
        if (haircut >= BPS) return 0; // degenerate fee regime — any positive output clears a 0 bound
        return FullMath.mulDiv(implied, BPS - haircut, BPS);
    }

    /// @dev Pool-TWAP-implied output for `amountIn` (token1-per-token0, 1e18) — replicates
    ///      `VaultMath.twapImpliedOut` (same window, same fail-closed staleness discipline).
    function _twapImpliedOut(PoolId id, bool zeroForOne, uint256 amountIn) internal view returns (uint256) {
        uint256 price = _poolTwapPrice(id);
        return zeroForOne ? FullMath.mulDiv(amountIn, price, 1e18) : FullMath.mulDiv(amountIn, 1e18, price);
    }

    /// @dev Hook-TWAP price (1e18, token1/token0) over SWAP_TWAP_WINDOW_SEC; falls back to spot only
    ///      before the oracle has history (a fresh pool — the same posture the vault takes), and
    ///      fails CLOSED (TwapStale) on a dormant pool whose reading would be a stale extrapolation.
    function _poolTwapPrice(PoolId id) internal view returns (uint256) {
        (uint160 sqrtSpot,,,) = poolManager.getSlot0(id);
        uint160 sqrtPriceX96 = sqrtSpot;
        try hook.consultTwapTick(id, SWAP_TWAP_WINDOW_SEC) returns (int24 twapTick, bool ready) {
            if (ready) {
                (uint32 ageSec, bool has) = hook.twapObservationAge(id);
                if (has && ageSec > TWAP_MAX_STALENESS_SEC) revert TwapStale();
                sqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);
            }
        } catch {
            // consult reverted — degrade to spot (fail-safe), same as VaultMath._consultTwap.
        }
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        return FullMath.mulDiv(priceX96, 1e18, 1 << 96);
    }

    // DESIGN: MAX_ENTRY_VS_DEPTH_BPS (spec §6 "size vs depth") is enforced as the SPOT-PRICE MOVE a
    // single swap causes — a fee-independent proxy for entry-notional-vs-pool-depth that is cheap to
    // compute and directly bounds pool disruption. Kept strictly below the vault's 2% deposit TWAP
    // gate so a swap the index accepts never trips the subsequent FeraVault.deposit gate.
    /// @dev Bound the spot move a single swap caused: |Δprice| / priceBefore ≤ MAX_ENTRY_VS_DEPTH_BPS.
    function _requireDepthOk(uint160 sqrtBefore, uint160 sqrtAfter) internal pure {
        uint256 pB = FullMath.mulDiv(uint256(sqrtBefore), uint256(sqrtBefore), 1 << 96);
        uint256 pA = FullMath.mulDiv(uint256(sqrtAfter), uint256(sqrtAfter), 1 << 96);
        uint256 diff = pB > pA ? pB - pA : pA - pB;
        if (pB == 0 || FullMath.mulDiv(diff, BPS, pB) > MAX_ENTRY_VS_DEPTH_BPS) revert EntryExceedsDepth();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // Views — ERC-4626-style + index composition
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IFeraIndexVault
    function totalAssets() public view returns (uint256) {
        return _nav();
    }

    /// @inheritdoc IFeraIndexVault
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 nav = _nav();
        return (supply == 0 || nav == 0) ? assets : FullMath.mulDiv(assets, supply, nav);
    }

    /// @inheritdoc IFeraIndexVault
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : FullMath.mulDiv(shares, _nav(), supply);
    }

    /// @inheritdoc IFeraIndexVault
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @inheritdoc IFeraIndexVault
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @inheritdoc IFeraIndexVault
    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IFeraIndexVault
    function members() external view returns (bytes32[] memory ids) {
        uint256 n = memberIds.length;
        ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = PoolId.unwrap(memberIds[i]);
        }
    }

    /// @inheritdoc IFeraIndexVault
    function memberInfo(PoolId poolId) external view returns (MemberView memory) {
        Member storage m = memberOf[poolId];
        return MemberView({
            poolId: PoolId.unwrap(poolId),
            share: m.share,
            quoteIsToken0: m.quoteIsToken0,
            weightBps: m.weightBps
        });
    }

    /// @inheritdoc IFeraIndexVault
    function memberValue(PoolId poolId) external view returns (uint256) {
        Member storage m = memberOf[poolId];
        if (!m.exists) return 0;
        return _memberValueStorage(m, poolId);
    }
}
