// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IEmissionsController} from "./interfaces/IEmissionsController.sol";
import {IFeraToken} from "./interfaces/IFeraToken.sol";
import {FeraConstants} from "./libraries/FeraConstants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title EmissionsController
/// @notice Weekly epoch clock and mint authority for the 90% usage-emitted FERA. Each epoch it may
///         emit at most `min( cap(t), β × revenueValuedInFera )` (INV-7) — a dividend of activity,
///         never a subsidy. Emitted FERA backs the esFERA that the Distributor pays out.
/// @dev    `owner` is the 48h Treasury timelock, so β is timelocked (§7). Mint authority over FERA
///         is granted to THIS contract via FeraToken.setEmissionsController (one-shot, immutable).
contract EmissionsController is IEmissionsController, Ownable {
    IFeraToken public immutable fera;

    /// @dev esFERA backing sink: emitted FERA is minted here so vests/exits are 1:1 redeemable.
    address public immutable esFera;

    /// @dev The emissions keeper permitted to finalize epochs (bounded by INV-7 amount cap).
    address public keeper;

    /// @dev Epoch 0 starts at `genesisTs`; epoch N spans [genesisTs+N*len, genesisTs+(N+1)*len).
    uint256 public immutable genesisTs;

    /// @inheritdoc IEmissionsController
    uint256 public beta; // 1e18-fixed; default 0.8e18; timelocked via owner.

    uint256 public totalEmitted; // cumulative FERA emitted across all epochs (≤ 90% of supply).
    mapping(uint256 => bool) public finalized;
    /// @dev FERA funded/minted per epoch. The Distributor asserts its posted totalEsFera == this
    ///      (R-19 / D-M9 C2 — bounds a compromised root-poster to the funded envelope).
    mapping(uint256 => uint256) public emittedOf;

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }

    constructor(IFeraToken fera_, address esFera_, address keeper_, address timelockOwner)
        Ownable(timelockOwner)
    {
        if (esFera_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        fera = fera_;
        esFera = esFera_;
        keeper = keeper_;
        genesisTs = block.timestamp;
        beta = FeraConstants.BETA_DEFAULT_WAD;
    }

    /// @inheritdoc IEmissionsController
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesisTs) / FeraConstants.EPOCH_LENGTH;
    }

    /// @inheritdoc IEmissionsController
    function epochEnd(uint256 epochId) public view returns (uint256) {
        return genesisTs + (epochId + 1) * FeraConstants.EPOCH_LENGTH;
    }

    /// @inheritdoc IEmissionsController
    /// @dev Placeholder S-curve. TODO(spec-freeze): PARAMS.md#cap_logistic_{L,k,t0} — replace this
    ///      linear ramp with the frozen logistic. Returns CUMULATIVE emittable up to time `t`.
    function capAt(uint256 t) public view returns (uint256) {
        if (t <= genesisTs) return 0;
        uint256 elapsed = t - genesisTs;
        uint256 horizon = 4 * 365 days; // ~4-year horizon (placeholder)
        if (elapsed >= horizon) return FeraConstants.CAP_LOGISTIC_L;
        return (FeraConstants.CAP_LOGISTIC_L * elapsed) / horizon;
    }

    /// @inheritdoc IEmissionsController
    function finalizeEpoch(uint256 epochId, uint256 emissionRequested, uint256 revenueValuedInFera, uint256 feraTwap)
        external
        onlyKeeper
        returns (uint256 emitted)
    {
        if (block.timestamp < epochEnd(epochId)) revert EpochNotOver();
        if (finalized[epochId]) revert EpochAlreadyFinalized();

        // ═══════════════════════════════════════════════════════════════════════════════════
        // PT-5 / INV-13 HOOK — ACCEPTED (MASTER_SPEC §13 PT-5); boost weighting is off-chain (§9)
        // ─────────────────────────────────────────────────────────────────────────────────────
        // PT-5 (ACCEPTED): the INV-7 emission cap MUST be enforced on the TOTAL, AFTER boost
        // weighting — boost REDISTRIBUTES a fixed capped pool, it NEVER boosts-then-mints. This
        // contract mints the epoch TOTAL (`emitted`) against `min(cap, β·revenue)` BELOW; the
        // per-staker ≤2x boost is applied by the off-chain emissions pipeline (§9) INSIDE this
        // total when it builds the Merkle leaves, so no boost can inflate minted supply. Once the
        // INV-13 boost fix is frozen, add an on-chain assertion that the Distributor's posted
        // totalEsFera (Σ leaf amounts) == `emitted` for this epoch. See OPEN_DECISIONS.md#PT-5.
        // ═══════════════════════════════════════════════════════════════════════════════════

        // Cumulative cap headroom remaining at this epoch's end.
        uint256 cap = capAt(epochEnd(epochId));
        uint256 marginalCap = cap > totalEmitted ? cap - totalEmitted : 0;

        // β × revenue bound (INV-7 second arm).
        uint256 revenueBound = (beta * revenueValuedInFera) / 1e18;

        // INV-7 envelope = min(cap, β·rev). The keeper funds the pipeline's committed ΣE_p
        // (`emissionRequested`), which MUST fit inside the envelope. Per D-BK-12 the pipeline's total
        // may be strictly BELOW the envelope (per-pool revenue locks leave un-emittable remainders
        // that are never redistributed) — INV-7 is an inequality, so funding exactly ΣE_p (never
        // recomputing/padding to the envelope) is compliant AND is what lets the Distributor bind
        // Σleaves == emitted on-chain (R-19 / D-M9 C2).
        uint256 envelope = marginalCap < revenueBound ? marginalCap : revenueBound; // min(cap, β·rev)
        if (emissionRequested > envelope) revert EmissionBoundExceeded();
        emitted = emissionRequested;

        finalized[epochId] = true;
        totalEmitted += emitted;
        emittedOf[epochId] = emitted; // R-19: the Distributor asserts totalEsFera == this.

        // Mint the epoch's FERA as esFERA backing. The keeper separately posts the Merkle root to
        // the Distributor with totalEsFera == emitted; claims then mint esFERA against this backing.
        if (emitted != 0) fera.mint(esFera, emitted);

        emit EpochFinalized(epochId, cap, revenueBound, emitted, feraTwap);
    }

    /// @notice Timelocked β update (owner == 48h Treasury timelock). Hard on-chain ceiling 0.9
    ///         (D-M9 C3 / SEC-3 #5 — was 1.0). Wash-farm break-even inverts at β ≥ 1/0.9 ≈ 1.111;
    ///         no timelock action can widen this cap (it lives in code, the Gamma lesson).
    function setBeta(uint256 newBetaWad) external onlyOwner {
        require(newBetaWad > 0 && newBetaWad <= FeraConstants.BETA_MAX_WAD, "beta");
        beta = newBetaWad;
    }

    /// @notice Rotate the emissions keeper (owner == timelock). Redundant keepers per §10.
    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }
}
