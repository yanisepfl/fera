// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {FeraToken} from "../../src/FeraToken.sol";
import {EmissionsController} from "../../src/EmissionsController.sol";
import {Distributor} from "../../src/Distributor.sol";
import {EsFera} from "../../src/EsFera.sol";
import {AnchorStaking} from "../../src/AnchorStaking.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";

import {IFeraToken} from "../../src/interfaces/IFeraToken.sol";
import {IEmissionsController} from "../../src/interfaces/IEmissionsController.sol";
import {IEsFera} from "../../src/interfaces/IEsFera.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Drives a full epoch lifecycle across the three-cycle money path
///      EmissionsController → Distributor → EsFera (backed by FeraToken, forfeits into AnchorStaking):
///      finalize an epoch (mint FERA backing), post a single-leaf Merkle root, claim esFERA, then
///      redeem it via linear vest (`claimVested`) or the 50%-haircut `instantExit` (forfeit split).
///      The invariant contract asserts the cross-contract value-conservation laws hold at EVERY step.
///
///      Single-leaf trick: an OZ sorted-pair tree of ONE leaf has `root == leaf` and an EMPTY proof,
///      so the handler can post `root = keccak256(abi.encode(epochId, actor, kind, amount))` and the
///      chosen actor claims with `proof = []`. `totalEsFera == emitted` keeps R-19's Σleaves binding.
contract EmissionsEpochHandler is Test {
    EmissionsController internal ec;
    Distributor internal dist;
    EsFera internal es;
    FeraToken internal fera;
    AnchorStaking internal staking;

    address[3] internal actors;

    uint256 public nextEpoch; // next epoch to finalize (sequential)
    uint256 public ghostBurned; // FERA burned via instant-exit forfeit thirds (supply decreases)

    // per-epoch bookkeeping
    mapping(uint256 => uint256) public emittedFor;
    mapping(uint256 => address) public actorFor;
    mapping(uint256 => bool) public posted;
    mapping(uint256 => bool) public claimed;
    uint256[] public finalizedEpochs;

    function init(EmissionsController ec_, Distributor dist_, EsFera es_, FeraToken fera_, AnchorStaking staking_)
        external
    {
        ec = ec_;
        dist = dist_;
        es = es_;
        fera = fera_;
        staking = staking_;
        actors = [makeAddr("emitA"), makeAddr("emitB"), makeAddr("emitC")];
    }

    function finalizedCount() external view returns (uint256) {
        return finalizedEpochs.length;
    }

    // ── Actions (the only fuzzed selectors) ────────────────────────────────────────────────

    /// Warp past the next epoch's end and finalize it, funding exactly the pipeline's committed total
    /// (a fraction of the min(cap, β·rev) envelope). Sequential — enforces the real clock.
    function finalizeNext(uint256 revenueSeed, uint256 fracSeed) external {
        uint256 e = nextEpoch;
        vm.warp(ec.epochEnd(e) + 1);

        uint256 revenue = bound(revenueSeed, 1e18, 1e24);
        uint256 cap = ec.capAt(ec.epochEnd(e));
        uint256 marginalCap = cap > ec.totalEmitted() ? cap - ec.totalEmitted() : 0;
        uint256 revBound = (ec.beta() * revenue) / 1e18;
        uint256 envelope = marginalCap < revBound ? marginalCap : revBound;
        if (envelope == 0) return;

        uint256 requested = (envelope * bound(fracSeed, 1, FeraConstants.BPS)) / FeraConstants.BPS;
        if (requested == 0) requested = 1;
        if (requested > envelope) requested = envelope;

        uint256 emitted = ec.finalizeEpoch(e, requested, revenue, 1e18);
        emittedFor[e] = emitted;
        actorFor[e] = actors[e % 3];
        finalizedEpochs.push(e);
        nextEpoch = e + 1;
    }

    /// Post the single-leaf root for a finalized-not-posted epoch (rootPoster == this handler).
    function postRootFor(uint256 epochSeed) external {
        uint256 n = finalizedEpochs.length;
        if (n == 0) return;
        uint256 e = finalizedEpochs[epochSeed % n];
        if (posted[e] || emittedFor[e] == 0) return;
        address actor = actorFor[e];
        bytes32 leaf = keccak256(abi.encode(e, actor, uint8(0), emittedFor[e]));
        dist.postRoot(e, leaf, emittedFor[e]); // totalEsFera == emitted (R-19 binding)
        posted[e] = true;
    }

    /// The epoch's chosen actor claims its esFERA (single leaf ⇒ empty proof).
    function claimFor(uint256 epochSeed) external {
        uint256 n = finalizedEpochs.length;
        if (n == 0) return;
        uint256 e = finalizedEpochs[epochSeed % n];
        if (!posted[e] || claimed[e]) return;
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(actorFor[e]);
        dist.claim(e, 0, emittedFor[e], proof);
        claimed[e] = true;
    }

    /// An actor claims whatever FERA has linearly vested so far.
    function claimVestedFor(uint256 actorSeed) external {
        address a = actors[actorSeed % 3];
        if (es.claimable(a) == 0) return;
        vm.prank(a);
        es.claimVested();
    }

    /// An actor instant-exits some still-locked esFERA (50% haircut, forfeit split). Tracks the burn.
    function instantExitFor(uint256 actorSeed, uint256 amtSeed) external {
        address a = actors[actorSeed % 3];
        uint256 locked = es.lockedOf(a);
        if (locked == 0) return;
        uint256 amt = bound(amtSeed, 1, locked);
        uint256 supplyBefore = fera.totalSupply();
        vm.prank(a);
        es.instantExit(amt);
        ghostBurned += supplyBefore - fera.totalSupply();
    }

    /// Advance the clock (lets vests progress between other actions).
    function warp(uint256 dtSeed) external {
        vm.warp(block.timestamp + bound(dtSeed, 1 hours, 30 days));
    }
}

/// @notice Cross-contract value conservation across a full emissions epoch (INV-7/INV-8/INV-9 + the
///         R-19/R-20 backing laws), asserted as stateful invariants over interleaved
///         finalize/post/claim/vest/exit sequences.
contract EmissionsConservationInvariant is StdInvariant, Test {
    FeraToken internal fera;
    EmissionsController internal ec;
    Distributor internal dist;
    EsFera internal es;
    AnchorStaking internal staking;
    RevenueDistributor internal rev;
    EmissionsEpochHandler internal handler;

    address internal treasury = makeAddr("treasury");
    address internal ops = makeAddr("ops");

    uint256 internal genesisSupply;

    function setUp() public {
        handler = new EmissionsEpochHandler();

        // Genesis 10% FERA to this contract (acts as genesis treasury holder).
        fera = new FeraToken(address(this));
        genesisSupply = fera.totalSupply();

        // AnchorStaking ↔ RevenueDistributor ctor cycle: predict staking's address.
        address predictedStaking = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rev = new RevenueDistributor(predictedStaking, treasury, ops);
        staking = new AnchorStaking(IERC20(address(fera)), IRevenueDistributor(address(rev)), address(this));
        require(address(staking) == predictedStaking, "staking addr");

        // EmissionsController ↔ EsFera ↔ Distributor 3-cycle: precompute the CREATE addresses.
        uint256 base = vm.getNonce(address(this));
        address addrEc = vm.computeCreateAddress(address(this), base);
        address addrEs = vm.computeCreateAddress(address(this), base + 1);
        address addrDist = vm.computeCreateAddress(address(this), base + 2);

        // keeper (finalize) + rootPoster = the handler, so it can drive both. timelock = this.
        ec = new EmissionsController(IFeraToken(address(fera)), addrEs, address(handler), address(this));
        es = new EsFera(
            IFeraToken(address(fera)), IAnchorStaking(address(staking)), IRevenueDistributor(address(rev)), addrDist
        );
        dist = new Distributor(IEsFera(address(es)), address(handler), IEmissionsController(address(ec)));
        require(address(ec) == addrEc && address(es) == addrEs && address(dist) == addrDist, "cycle addr");

        fera.setEmissionsController(address(ec)); // this contract deployed FERA ⇒ allowed
        staking.addRewardToken(address(fera)); // so forfeit stakers-third can be booked (REC-8)
        staking.setForfeitNotifier(address(es));

        handler.init(ec, dist, es, fera, staking);

        bytes4[] memory sel = new bytes4[](6);
        sel[0] = handler.finalizeNext.selector;
        sel[1] = handler.postRootFor.selector;
        sel[2] = handler.claimFor.selector;
        sel[3] = handler.claimVestedFor.selector;
        sel[4] = handler.instantExitFor.selector;
        sel[5] = handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// SEC-3 #8 / R-20: the escrow's FERA balance ALWAYS covers its outstanding esFERA obligation —
    /// every vest is redeemable 1:1, no drain can make a later vester's claim revert (insolvency).
    function invariant_escrowSolvent() public view {
        assertGe(fera.balanceOf(address(es)), es.outstandingEsFera(), "escrow undercollateralized");
    }

    /// R-19: cumulative esFERA claimed per epoch never exceeds the funded envelope (== emitted), so a
    /// posted root can never mint esFERA beyond what the controller actually minted as backing.
    function invariant_claimedWithinEmitted() public view {
        uint256 n = handler.finalizedCount();
        for (uint256 i; i < n; ++i) {
            uint256 e = handler.finalizedEpochs(i);
            // The Distributor only records totalEsFeraOf on postRoot; before that it is 0 (nothing
            // claimable yet). Once posted, R-19 binds it to the controller's funded amount.
            if (handler.posted(e)) {
                assertEq(dist.totalEsFeraOf(e), ec.emittedOf(e), "totalEsFera != emitted (R-19)");
            }
            assertLe(dist.claimedOf(e), dist.totalEsFeraOf(e), "claimed > totalEsFera (R-19)");
        }
    }

    /// Global FERA conservation across all three contracts: the only mint path is the controller's
    /// per-epoch backing mint (Σ = totalEmitted) and the only burn path is the instant-exit forfeit
    /// third. So supply == genesis + Σemitted − Σburned at all times (no value created anywhere).
    function invariant_feraConservation() public view {
        assertEq(
            fera.totalSupply() + handler.ghostBurned(),
            genesisSupply + ec.totalEmitted(),
            "FERA supply not conserved across emissions path"
        );
    }

    /// The controller never mints past the 90% usage cap (fixed-supply guard, INV-7 cumulative arm).
    function invariant_totalEmittedUnderCap() public view {
        assertLe(ec.totalEmitted(), FeraConstants.CAP_LOGISTIC_L, "totalEmitted exceeded logistic L");
    }
}
