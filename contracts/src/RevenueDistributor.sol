// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IRevenueDistributor} from "./interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "./interfaces/IAnchorStaking.sol";
import {FeraConstants} from "./libraries/FeraConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RevenueDistributor
/// @notice Immutable 50/25/25 pull-based revenue split (stakers / treasury / ops). Every inflow is
///         partitioned so that toStakers + toTreasury + toOps == amount EXACTLY — no rounding dust
///         ever escapes accounting (INV-10). All three recipients are immutable (INV-12).
/// @dev    Pull model (no push): recipients withdraw their own accrued balances, so a hostile or
///         reverting recipient cannot block the split for the others.
contract RevenueDistributor is IRevenueDistributor {
    using SafeERC20 for IERC20;

    address public immutable stakers; // AnchorStaking (50%)
    address public immutable treasury; // Treasury (25%)
    address public immutable ops; // ops multisig / sink (25%)

    /// @dev pending[recipient][token] — pull-balance owed.
    mapping(address => mapping(address => uint256)) internal _pending;
    /// @dev Total credited-but-not-yet-pulled per token = Σ_pending[*][token]. The R-22 balance-delta
    ///      guard keeps this ≤ balanceOf(token) at all times, so accounting can never exceed real
    ///      holdings and a `pull` can never revert for insufficient balance (INV-10: Σpending ≤ bal).
    mapping(address => uint256) internal _accounted;

    constructor(address stakers_, address treasury_, address ops_) {
        if (stakers_ == address(0) || treasury_ == address(0) || ops_ == address(0)) revert ZeroAddress();
        stakers = stakers_;
        treasury = treasury_;
        ops = ops_;
    }

    /// @inheritdoc IRevenueDistributor
    /// @dev Caller MUST have transferred `amount` of `token` to this contract first (EsFera / Vault
    ///      do exactly that). R-22: we no longer TRUST that — we VERIFY it via a balance-delta guard.
    ///      The contract's real balance must cover every credit that is still owed (`_accounted`) plus
    ///      this new `amount`; otherwise the caller is trying to inflate `_pending` above real holdings
    ///      (which would permanently brick pull for that token), so we revert. This makes crediting
    ///      permissionless-but-safe: only funds actually received can ever be booked.
    function notifyRevenue(address token, uint256 amount) external {
        _notify(token, amount, true);
    }

    /// @inheritdoc IRevenueDistributor
    function notifyRevenueNoStakers(address token, uint256 amount) external {
        _notify(token, amount, false);
    }

    /// @dev Shared 50/25/25 partition + balance-delta guard (R-22). `stakersEligible=false` folds
    ///      the stakers' leg into treasury instead (v3.1 no-staker routing, §9 of
    ///      contracts/VAULT_STRATEGY_V3.md) — the ONLY difference from the historical `notifyRevenue`
    ///      behavior; `notifyRevenue` itself (stakersEligible=true) is byte-for-byte unchanged.
    /// @dev OD-18 CLOSED (Low, re-flagged by an independent audit tool): `notifyRevenueNoStakers` is
    ///      permissionless with no caller restriction, so it previously TRUSTED whoever called it
    ///      (normally VaultFees, which does check `AnchorStaking.totalStaked()==0` on-chain first) —
    ///      a direct external caller could invoke it whenever the distributor holds unaccounted
    ///      balance, folding that amount's stakers-50% leg into treasury even while stakers ARE
    ///      actively staked. Self-correcting fix (the exact one OPEN_DECISIONS.md#OD-18 recommended):
    ///      re-derive eligibility here, on-chain, instead of trusting the caller's claim. `stakers`
    ///      is always the real AnchorStaking deployment in production (never zero-address, checked
    ///      at construction) — the `code.length` guard only matters for a test double with no
    ///      bytecode, where the call would otherwise revert on ABI-decoding empty returndata.
    function _notify(address token, uint256 amount, bool stakersEligible) internal {
        if (amount == 0) return;
        if (!stakersEligible && stakers.code.length != 0 && IAnchorStaking(stakers).totalStaked() != 0) {
            stakersEligible = true;
        }

        // Balance-delta / pull-in guard (R-22). balanceOf ≥ _accounted + amount ⇔ the `amount` was
        // genuinely transferred in on top of everything still owed. Fee-on-transfer under-delivery
        // fails this closed (conservative: never over-credit); such tokens are pool-ineligible anyway.
        if (IERC20(token).balanceOf(address(this)) < _accounted[token] + amount) revert UnbackedRevenue();
        _accounted[token] += amount;

        uint256 toStakers = (amount * FeraConstants.REV_STAKERS_BPS) / FeraConstants.BPS;
        uint256 toTreasury = (amount * FeraConstants.REV_TREASURY_BPS) / FeraConstants.BPS;
        uint256 toOps = amount - toStakers - toTreasury; // remainder-to-last ⇒ no dust (INV-10)

        if (!stakersEligible) {
            // v3.1 no-staker routing: nobody is staked to fairly divide this pro-rata to — route the
            // would-be stakers' half to treasury instead of stranding it as an unclaimable pending
            // balance (or worse, a windfall for whoever stakes first). Still an EXACT partition.
            toTreasury += toStakers;
            toStakers = 0;
        }

        _pending[stakers][token] += toStakers;
        _pending[treasury][token] += toTreasury;
        _pending[ops][token] += toOps;

        emit RevenueReceived(token, amount);
        emit RevenueSplit(token, toStakers, toTreasury, toOps);
    }

    /// @inheritdoc IRevenueDistributor
    function pull(address token) external returns (uint256 amount) {
        amount = _pending[msg.sender][token];
        if (amount == 0) revert NothingToPull();
        _pending[msg.sender][token] = 0; // effects before interaction (CEI)
        _accounted[token] -= amount; // keep Σpending == _accounted ≤ balance (R-22)
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc IRevenueDistributor
    function pending(address who, address token) external view returns (uint256) {
        return _pending[who][token];
    }
}
