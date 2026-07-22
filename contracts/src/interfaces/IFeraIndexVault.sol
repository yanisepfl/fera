// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IFeraIndexVault — the FERA memecoin-LP index ("fIDX")
/// @notice One deposit (wWETH) → a diversified basket of tranche-0 ("Steady") FeraShare positions
///         across an allowlisted set of curated FERA memecoin pools. An ERC-4626-STYLE single-asset
///         vault (asset = wWETH): one token in, one token out. See contracts/INDEX_VAULT_SPEC.md.
/// @dev    DELIBERATE DEVIATION from the exact ERC-4626 function signatures: the mutators are
///         SLIPPAGE-PROTECTED (`deposit(assets,minSharesOut)` / `withdraw(shares,minAssetsOut)`)
///         rather than the standard receiver/owner variants, because entry/exit route real swaps
///         through the member pools and MUST be atomically bounded. The ERC-4626 *view* surface
///         (`asset`/`totalAssets`/`convertTo*`/`preview*`) is provided verbatim for integrators
///         (DefiLlama / Rabby). `withdraw` here has ERC-4626 `redeem` semantics (burns SHARES).
interface IFeraIndexVault {
    // ── Views: a member (poolId, tranche-0 share) of the index basket ─────────────────────────
    struct MemberView {
        bytes32 poolId; // v4 PoolId of the member pool
        address share; // the pool's tranche-0 ("Steady") FeraShare clone the index holds
        bool quoteIsToken0; // whether wWETH sorts as currency0 in the member pool
        uint16 weightBps; // target weight (bps of the basket); Σ over members == 10_000
    }

    // ── Events ────────────────────────────────────────────────────────────────────────────────
    /// @notice A depositor added `assets` wWETH and minted `shares` fIDX; `navAfter` is the post-mint
    ///         basket NAV (wWETH, TWAP-priced) for off-chain price-per-share reconciliation.
    event Deposit(address indexed user, uint256 assets, uint256 shares, uint256 navAfter);
    /// @notice A holder burned `shares` fIDX and received `assets` wWETH (proportional exit; the
    ///         memecoin legs were swapped back through their own pools within the slippage bound).
    event Withdraw(address indexed user, uint256 shares, uint256 assets);
    /// @notice A holder burned `shares` fIDX and took the basket IN KIND (pro-rata FeraShare tokens
    ///         + pro-rata idle wWETH) — the swap-free safety valve (spec §5 / INV-I5).
    event EmergencyRedeem(address indexed user, uint256 shares);
    /// @notice The timelock replaced the member set (and their target weights).
    event MembersUpdated(bytes32[] poolIds, uint16[] weightsBps);
    /// @notice The timelock re-weighted the existing member set within the §6 guardrails.
    event WeightsUpdated(uint16[] weightsBps);
    /// @notice The keeper moved `navMoved` wWETH-NAV of the basket from an overweight member `from`
    ///         to an underweight member `to` (bounded, cooled-down — spec §5 rebalance).
    event Rebalance(bytes32 indexed from, bytes32 indexed to, uint256 navMoved);
    /// @notice The timelock rotated the rebalance keeper.
    event KeeperUpdated(address indexed keeper);

    // ── Errors ────────────────────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error NoMembers(); // basket not configured (or fully emptied)
    error Slippage(); // minSharesOut / minAssetsOut / per-swap minOut breach — whole tx reverts
    error CooldownActive(); // the underlying vault's per-LP cooldown/transfer-lock is still active
    error EntryExceedsDepth(); // a single entry/exit swap moved spot > MAX_ENTRY_VS_DEPTH_BPS
    error TwapStale(); // the member pool's TWAP observation is stale — fail-closed (never on a swap that would trust spot)
    error OnlyKeeper();
    error OnlyPoolManager();
    error TooManyMembers(); // > MAX_MEMBERS
    error BadWeight(); // a member weight outside [MIN_WEIGHT_BPS, MAX_WEIGHT_BPS]
    error WeightSumNot100(); // Σ weights != 10_000
    error LengthMismatch();
    error DuplicateMember();
    error MemberNotFound();
    error MemberHasBalance(); // cannot drop a member the index still holds shares in (would strand value)
    error QuoteNotAsset(); // member pool's quote side is not wWETH
    error WrongHook(); // member pool does not route through the FERA hook (TWAP would be spoofable)
    error NotMemePool(); // v1 members must be MEME-regime pools (fee/surcharge model)
    error PoolNotCurated(); // pool/tranche-0 is unknown to the FeraVault
    error RebalanceTooSoon(); // < REBALANCE_COOLDOWN_SEC since the last rebalance
    error StepTooLarge(); // navBps > MAX_REBALANCE_STEP_BPS
    error NotOverweight(); // `from` is not drifted above target by > REBALANCE_BAND_BPS
    error NotUnderweight(); // `to` is not drifted below target by > REBALANCE_BAND_BPS
    error NavZero(); // basket NAV is zero — cannot price shares / weights

    // ── Mutators (spec §5) ─────────────────────────────────────────────────────────────────────
    /// @notice Deposit `assets` wWETH; acquire each memecoin leg by swapping through that member's
    ///         FERA pool (TWAP-bounded minOut, atomic), deposit both legs into the member's tranche 0,
    ///         and mint fIDX by the TWAP-NAV delta (min(dNAV, paid); first deposit burns
    ///         MINIMUM_LIQUIDITY). Reverts the WHOLE tx on any leg's slippage/depth breach.
    function deposit(uint256 assets, uint256 minSharesOut) external returns (uint256 shares);

    /// @notice Burn `shares` fIDX; redeem the pro-rata FeraShare of every member (two tokens out),
    ///         swap each memecoin leg back to wWETH (TWAP-bounded), and transfer the total wWETH.
    ///         Reverts if the total is below `minAssetsOut`. Subject to the underlying vault's per-LP
    ///         cooldown (see contract NatSpec) — use `emergencyRedeemInKind` if a swap path is down.
    function withdraw(uint256 shares, uint256 minAssetsOut) external returns (uint256 assets);

    /// @notice Swap-free exit: burn `shares` and transfer the pro-rata FeraShare tokens themselves
    ///         (+ pro-rata idle wWETH) to the caller. The safety valve if a member's token becomes
    ///         unsellable. Reverts CooldownActive if inside the vault's share transfer-lock window
    ///         (fresh index deposits age the lock; aged shares always succeed — INV-I5).
    function emergencyRedeemInKind(uint256 shares) external;

    // ── Admin (timelock owner) ─────────────────────────────────────────────────────────────────
    /// @notice Replace the member set with `keys` at `weightsBps` (Σ == 10_000, each in
    ///         [MIN_WEIGHT_BPS, MAX_WEIGHT_BPS], count ≤ MAX_MEMBERS). Every key is validated against
    ///         the FeraVault (curated, MEME, quote == wWETH, real hook). A currently-held member that
    ///         is dropped reverts unless the index's balance in it is 0 (no value stranding).
    function setMembers(PoolKey[] calldata keys, uint16[] calldata weightsBps) external;

    /// @notice Re-weight the EXISTING member set (same order/length) within the §6 guardrails.
    function setWeights(uint16[] calldata weightsBps) external;

    /// @notice Rotate the rebalance keeper.
    function setKeeper(address newKeeper) external;

    // ── Keeper (bounded) ───────────────────────────────────────────────────────────────────────
    /// @notice Move at most `navBps` (≤ MAX_REBALANCE_STEP_BPS) of NAV from overweight member `from`
    ///         to underweight member `to`, when each has drifted past REBALANCE_BAND_BPS from target.
    ///         Same swap bounds as entry/exit. Cooldown REBALANCE_COOLDOWN_SEC between calls.
    function rebalance(PoolId from, PoolId to, uint256 navBps) external;

    // ── ERC-4626-style views (wWETH-denominated) ───────────────────────────────────────────────
    /// @notice The vault's underlying asset (wWETH).
    function asset() external view returns (address);
    /// @notice Total basket NAV in wWETH (Σ member FeraShare value at the vault's TWAP + idle wWETH).
    function totalAssets() external view returns (uint256);
    /// @notice Optimistic shares for `assets` (ignores entry cost — an UPPER bound on the real mint).
    function convertToShares(uint256 assets) external view returns (uint256);
    /// @notice wWETH backing `shares` at current NAV (BEFORE exit cost — an upper bound on redemption).
    function convertToAssets(uint256 shares) external view returns (uint256);
    /// @notice Alias of `convertToShares` (informational; the real mint is ≤ this, spec §5).
    function previewDeposit(uint256 assets) external view returns (uint256);
    /// @notice Alias of `convertToAssets` (informational; the real redemption is ≤ this).
    function previewRedeem(uint256 shares) external view returns (uint256);
    /// @notice ERC-4626 `maxDeposit` (unbounded on-chain; UI/keeper enforce OD-6 TVL caps off-chain).
    function maxDeposit(address) external view returns (uint256);

    // ── Index views ────────────────────────────────────────────────────────────────────────────
    /// @notice The member pool ids, in iteration order.
    function members() external view returns (bytes32[] memory);
    /// @notice Full descriptor of member `id` (reverts-free: `share == 0` ⇒ not a member).
    function memberInfo(PoolId id) external view returns (MemberView memory);
    /// @notice The current wWETH-NAV the index's stake in member `id` is worth (TWAP-priced).
    function memberValue(PoolId id) external view returns (uint256);
    /// @notice The keeper allowed to call `rebalance`.
    function keeper() external view returns (address);
}
