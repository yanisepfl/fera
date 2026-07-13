// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IEsFera} from "./interfaces/IEsFera.sol";
import {IFeraToken} from "./interfaces/IFeraToken.sol";
import {IAnchorStaking} from "./interfaces/IAnchorStaking.sol";
import {IRevenueDistributor} from "./interfaces/IRevenueDistributor.sol";
import {FeraConstants} from "./libraries/FeraConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title EsFera (esFERA)
/// @notice Non-transferable escrowed FERA. Emissions arrive here as esFERA; each mint opens a
///         ~6-month linear vest to FERA 1:1. Instant-exit takes a 50% haircut; the forfeited
///         half is routed 1/3 burn / 1/3 stakers / 1/3 RevenueDistributor, VALUE-CONSERVING (INV-9).
/// @dev    Deliberately NOT an ERC-20: there is no transfer surface, so non-transferability is
///         structural, not a guarded flag. Backing FERA is held by this contract; the Emissions
///         Controller funds it 1:1 with esFERA issued (see funding wiring TODO).
contract EsFera is IEsFera {
    using SafeERC20 for IERC20;

    IFeraToken public immutable fera;
    IAnchorStaking public immutable staking;
    IRevenueDistributor public immutable revenueDistributor;

    /// @dev The only address allowed to mint esFERA + open vests (the Distributor on claim).
    address public immutable minter;

    /// @dev Outstanding esFERA obligation = Σ(minted) − Σ(FERA redeemed via vest) − Σ(instant-exit
    ///      principal). Backing invariant (SEC-3 #8): this NEVER exceeds the FERA this contract
    ///      holds — asserted on every mintAndVest so a vest can only open against real backing.
    uint256 public outstandingEsFera;

    mapping(address => Vest[]) internal _vests;

    /// @dev Zero-address guard on the write-once minter wiring (defense-in-depth; deploy sets it).
    error ZeroAddress();

    modifier onlyMinter() {
        if (msg.sender != minter) revert OnlyMinter();
        _;
    }

    constructor(IFeraToken fera_, IAnchorStaking staking_, IRevenueDistributor revenueDistributor_, address minter_) {
        if (minter_ == address(0)) revert ZeroAddress();
        fera = fera_;
        staking = staking_;
        revenueDistributor = revenueDistributor_;
        minter = minter_;
    }

    /// @inheritdoc IEsFera
    function mintAndVest(address account, uint256 amount) external onlyMinter {
        if (amount == 0) revert ZeroAmount();
        // Backing invariant (SEC-3 #8): this contract must hold ≥ Σ(outstanding esFERA) in FERA.
        // The EmissionsController mints the matching FERA here when it funds the epoch (BEFORE any
        // claim). Assert the new obligation is fully covered so a vest can never be opened that the
        // escrow cannot ultimately redeem 1:1 — vested esFERA never exceeds FERA held/owed.
        uint256 newOutstanding = outstandingEsFera + amount;
        if (IERC20(address(fera)).balanceOf(address(this)) < newOutstanding) revert Undercollateralized();
        outstandingEsFera = newOutstanding;

        uint64 start = uint64(block.timestamp);
        uint64 end = uint64(block.timestamp + FeraConstants.ES_VEST_DURATION);
        _vests[account].push(Vest({amount: amount, claimed: 0, exited: 0, startTs: start, endTs: end}));
        emit VestStarted(account, amount, start, end);
    }

    /// @inheritdoc IEsFera
    function claimVested() external returns (uint256 feraOut) {
        Vest[] storage vs = _vests[msg.sender];
        uint256 len = vs.length;
        for (uint256 i; i < len; ++i) {
            // Claimable = the vested-by-time principal, capped at what remains after early exits
            // (amount − exited), minus what was already claimed. The cap is what makes the grant
            // conserving: exited principal can never be re-vested and re-claimed (R-20).
            uint256 unlocked = _unlockedOf(vs[i]);
            uint256 owed = unlocked - vs[i].claimed;
            if (owed != 0) {
                vs[i].claimed = unlocked;
                feraOut += owed;
            }
        }
        if (feraOut == 0) revert NothingVesting();
        // Obligation discharged 1:1 by the FERA leaving the escrow (keeps outstanding == backing).
        outstandingEsFera -= feraOut;
        emit VestClaimed(msg.sender, feraOut); // D-BK-9 / F-9
        // CEI: state fully updated above; single external transfer last.
        // SEC-7: SafeERC20 for money-path consistency (FERA is a standard OZ ERC20; safeTransfer future-proofs).
        IERC20(address(fera)).safeTransfer(msg.sender, feraOut);
    }

    /// @inheritdoc IEsFera
    /// @dev Consumes `amount` of still-locked (unvested, unclaimed) esFERA principal, newest-first.
    function instantExit(uint256 amount) external returns (uint256 feraOut) {
        if (amount == 0) revert ZeroAmount();
        _consumeLocked(msg.sender, amount); // reverts if caller lacks `amount` locked esFERA
        // `amount` esFERA ceases to exist; the matching FERA (feraOut + haircut) leaves below, so
        // the obligation drops by `amount` and outstanding stays == FERA backing.
        outstandingEsFera -= amount;

        // Haircut: user keeps (1 - 50%) as FERA; the rest is forfeited and re-routed.
        uint256 haircut = (amount * FeraConstants.INSTANT_EXIT_HAIRCUT_BPS) / FeraConstants.BPS;
        feraOut = amount - haircut;

        emit InstantExit(msg.sender, amount, feraOut, haircut);
        _routeForfeit(haircut);

        IERC20(address(fera)).safeTransfer(msg.sender, feraOut); // SEC-7: SafeERC20
    }

    /// @dev Split `haircut` into exact thirds so nothing is created/destroyed:
    ///      burned + toStakers + toRevenue == haircut  (INV-9).
    ///      F-4 / PARAMS.md#FORFEIT_BURN_FRAC: the BURN third takes the ≤2-wei rounding remainder
    ///      (conservative direction — dust is destroyed, never paid out).
    function _routeForfeit(uint256 haircut) internal {
        uint256 toStakers = haircut / FeraConstants.FORFEIT_PARTS;
        uint256 toRevenue = haircut / FeraConstants.FORFEIT_PARTS;
        uint256 burned = haircut - toStakers - toRevenue; // remainder-to-burn ⇒ exact conservation

        if (burned != 0) ERC20Burnable(address(fera)).burn(burned);
        if (toStakers != 0) {
            // REC-8: route the FERA to AnchorStaking AND book it as a distributable reward so stakers
            // actually accrue their third (was a stranded scaffold TODO). notifyForfeitShare folds it
            // into accPerShare[FERA]; it never reverts for us (holds until stakers/allowlist exist), so
            // an instant-exit can never be bricked by staking state. FERA must be an allowlisted reward
            // token in AnchorStaking for stakers to accrue this (deployment dependency — documented).
            IERC20(address(fera)).safeTransfer(address(staking), toStakers); // SEC-7: SafeERC20
            staking.notifyForfeitShare(toStakers);
        }
        if (toRevenue != 0) {
            IERC20(address(fera)).safeTransfer(address(revenueDistributor), toRevenue); // SEC-7: SafeERC20
            revenueDistributor.notifyRevenue(address(fera), toRevenue);
        }
        emit ForfeitRouted(burned, toStakers, toRevenue);
    }

    /// @inheritdoc IEsFera
    function claimable(address account) external view returns (uint256 total) {
        Vest[] storage vs = _vests[account];
        uint256 len = vs.length;
        for (uint256 i; i < len; ++i) {
            total += _unlockedOf(vs[i]) - vs[i].claimed;
        }
    }

    /// @notice Total still-locked esFERA (unvested, un-exited principal) for `account`.
    function lockedOf(address account) public view returns (uint256 locked) {
        Vest[] storage vs = _vests[account];
        uint256 len = vs.length;
        for (uint256 i; i < len; ++i) {
            locked += _lockedOf(vs[i]);
        }
    }

    // ── internals ─────────────────────────────────────────────────────────────────────────

    /// @dev Principal vested purely by the linear schedule (on the IMMUTABLE original amount).
    ///      This is monotone-increasing in time and independent of claims/exits — the property the
    ///      old code broke by shrinking `amount` (R-20). Caps at `amount` past endTs.
    function _vestedByTime(Vest storage v) internal view returns (uint256) {
        if (block.timestamp >= v.endTs) return v.amount;
        if (block.timestamp <= v.startTs) return 0;
        uint256 elapsed = block.timestamp - v.startTs;
        uint256 dur = v.endTs - v.startTs;
        return (v.amount * elapsed) / dur;
    }

    /// @dev The vested principal a grant may pay via claimVested: `min(vestedByTime, amount − exited)`.
    ///      Early-exited principal (`exited`) permanently reduces the claimable ceiling, so the total
    ///      released `claimed + exited` can never exceed `amount` (conservation, R-20). Because
    ///      exits only ever draw from `_lockedOf` (= amount − vestedByTime − exited ≥ 0), the cap is
    ///      always ≥ `claimed`, so the subtraction in claimVested/claimable never underflows.
    function _unlockedOf(Vest storage v) internal view returns (uint256) {
        uint256 vested = _vestedByTime(v);
        uint256 cap = v.amount - v.exited; // amount ≥ exited (exits bounded by locked principal)
        return vested < cap ? vested : cap;
    }

    /// @dev Still-locked (unvested AND un-exited) principal available for instantExit.
    ///      locked = amount − vestedByTime − exited, floored at 0 (once fully vested, nothing locked).
    function _lockedOf(Vest storage v) internal view returns (uint256) {
        uint256 gone = _vestedByTime(v) + v.exited;
        return v.amount > gone ? v.amount - gone : 0;
    }

    /// @dev Exit `amount` of still-locked (unvested) principal from newest vests, recording it in
    ///      each vest's `exited` accumulator (NEVER mutating the immutable `amount`). Reverts if the
    ///      caller lacks `amount` of locked principal — so Σexited is bounded by real locked principal
    ///      and can never regenerate (R-20). Newest-first ordering preserved.
    function _consumeLocked(address account, uint256 amount) internal {
        Vest[] storage vs = _vests[account];
        uint256 i = vs.length;
        while (i != 0 && amount != 0) {
            unchecked {
                --i;
            }
            uint256 lockedHere = _lockedOf(vs[i]);
            if (lockedHere == 0) continue;
            uint256 take = lockedHere < amount ? lockedHere : amount;
            vs[i].exited += take; // record early-exited principal; `amount` stays immutable
            amount -= take;
        }
        if (amount != 0) revert NothingVesting();
    }
}
