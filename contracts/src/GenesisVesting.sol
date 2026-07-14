// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IGenesisVesting} from "./interfaces/IGenesisVesting.sol";
import {FeraConstants} from "./libraries/FeraConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GenesisVesting
/// @notice Single-beneficiary, single-token vesting lock for the 10% FERA genesis allocation
///         (100,000,000 FERA — `FeraConstants.GENESIS_TREASURY_BPS` of `FERA_MAX_SUPPLY`). Stage-3
///         decided spec (`contracts/VAULT_STRATEGY_V3.md` §10): the treasury is now a plain EOA
///         (freely spendable, no timelock friction), so the genesis allocation is locked here
///         instead of being handed to it unlocked. Industry-standard shape: a **1-YEAR CLIFF**,
///         then **LINEAR VESTING over the following 3 YEARS** (4-year total horizon — deliberately
///         mirrors `EmissionsController`'s own ~4-year emission-cap horizon, a tokenomics-
///         consistency choice). Before the cliff, nothing is claimable. After it:
///             claimable(t) = total * (t - start - CLIFF) / (TOTAL_DURATION - CLIFF)
///         monotonic non-decreasing in `t`, capped at `total`, fully released at/after
///         `start + TOTAL_DURATION`.
/// @dev    Modeled on OpenZeppelin's `VestingWallet` linear-vest math (the same "total =
///         balanceOf(this) + released" self-computing schedule, so the exact genesis amount never
///         needs to be hardcoded or re-asserted here) but kept deliberately SINGLE-PURPOSE: one
///         fixed beneficiary, one fixed token, no arbitrary-asset sweep, no owner, no revocation —
///         NOT a general multi-grant system like `EsFera.sol`.
///
///         PERMISSIONLESS-PULL: `claim()` may be called by ANY address, but the released FERA
///         always transfers to the immutable `beneficiary` — never to `msg.sender`. This lets
///         automation (or anyone) trigger the release on the beneficiary's behalf without needing
///         its key, while the destination can never be redirected — the only choice documented per
///         the decided spec, in preference over an `onlyBeneficiary` gate (which would add no
///         fund-safety benefit here, since the payout address is fixed either way, and would only
///         risk claims being missed if the beneficiary key is ever unavailable).
contract GenesisVesting is IGenesisVesting {
    using SafeERC20 for IERC20;

    /// @inheritdoc IGenesisVesting
    IERC20 public immutable token;

    /// @inheritdoc IGenesisVesting
    address public immutable beneficiary;

    /// @inheritdoc IGenesisVesting
    uint64 public immutable start;

    /// @inheritdoc IGenesisVesting
    uint256 public released;

    constructor(IERC20 token_, address beneficiary_) {
        if (address(token_) == address(0) || beneficiary_ == address(0)) revert ZeroAddress();
        token = token_;
        beneficiary = beneficiary_;
        start = uint64(block.timestamp);
    }

    /// @inheritdoc IGenesisVesting
    function vestedAmount(uint256 timestamp) public view returns (uint256) {
        // Self-computing total (OZ VestingWallet pattern): balance still held + whatever already
        // left via `claim()`. Constant across the contract's life (claims move value from balance
        // to `released` 1:1, so their sum is invariant), so the schedule is exact even though the
        // exact genesis amount is never hardcoded here.
        uint256 total = token.balanceOf(address(this)) + released;
        return _vestingSchedule(total, timestamp);
    }

    /// @inheritdoc IGenesisVesting
    function releasable() public view returns (uint256) {
        return vestedAmount(block.timestamp) - released;
    }

    /// @inheritdoc IGenesisVesting
    function claim() external returns (uint256 amount) {
        amount = releasable();
        if (amount == 0) revert NothingToClaim();
        released += amount; // effects before interaction (CEI)
        emit Released(amount);
        token.safeTransfer(beneficiary, amount);
    }

    /// @dev The linear-with-cliff schedule: 0 before the cliff, `total` at/after the 4-year
    ///      horizon, exact linear interpolation over the 3-year window in between.
    function _vestingSchedule(uint256 total, uint256 timestamp) internal view returns (uint256) {
        uint256 cliffEnd = start + FeraConstants.GENESIS_VESTING_CLIFF_DURATION;
        uint256 vestEnd = start + FeraConstants.GENESIS_VESTING_TOTAL_DURATION;
        if (timestamp < cliffEnd) {
            return 0;
        } else if (timestamp >= vestEnd) {
            return total;
        } else {
            return (total * (timestamp - cliffEnd)) / (vestEnd - cliffEnd);
        }
    }
}
