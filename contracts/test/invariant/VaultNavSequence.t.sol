// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FeraVault} from "../../src/FeraVault.sol";
import {FeraHook} from "../../src/FeraHook.sol";
import {FeraShare} from "../../src/shares/FeraShare.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {IFeraVault} from "../../src/interfaces/IFeraVault.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";
import {MockAggregatorV3} from "../utils/Mocks.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {QW} from "../utils/QW.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Multi-tranche NAV conservation under interleaved deposit / withdraw / skimIdle /
///         rebalanceLimit / collectFees sequences (INV-4 / INV-15 / INV-16, per tranche) — v3
///         base+limit+idle surface (contracts/VAULT_STRATEGY_V3.md item 1: the legacy ladder +
///         drip/partialWithdraw/compound sequence this suite originally drove is removed).
///
///         Design: SWAP-FREE. No swaps ⇒ spot price is pinned at the 1:1 init, so there is NO
///         impermanent loss and token0+token1 is a faithful NAV measure; and NO fees, so NAV can only
///         move by rounding. Under those conditions a strategy rearrangement (skimIdle parks base
///         principal into `reserve`, rebalanceLimit redeploys it swap-free) or any other actor's
///         deposit/withdraw MUST leave a refHolder holder's redeemable value intact (never diluted,
///         never inflated at others' expense). Fee/IL paths are separately covered by
///         `ShareNavInvariant` (which swaps) and `BaseLimitNavInvariant` (self-swap/rebalanceBase).
///
///         A bounded action array (not StdInvariant) keeps each run a short, deterministic guarded
///         sequence — CI-safe, and avoids the TWAP deposit-gate going stale mid-run.
contract VaultNavSequenceTest is Deployers {
    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;
    MockAggregatorV3 internal feed;

    PoolKey internal memeKey;
    PoolId internal memeId;
    PoolKey internal rwaKey;
    PoolId internal rwaId;

    address internal refHolder = makeAddr("refHolder");
    address[2] internal foreign;

    uint256 internal constant COOLDOWN = 3_600;
    uint256 internal constant T0 = 10_000_000;
    uint256 internal constant SEED = 1_000e18; // refHolder deposit per position

    // (poolId, tranche) positions the refHolder seeds and foreigners churn.
    struct Pos {
        PoolId id;
        uint8 t;
    }

    Pos[3] internal positions;

    uint256 internal refIn; // total value the refHolder deposited (token0+token1 consumed)
    uint256 internal ghostForeignIn;
    uint256 internal ghostForeignOut;

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));
        feed = new MockAggregatorV3(8);
        feed.set(1e8, T0);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x2C71) << 14));
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), IAnchorStaking(address(0)), address(shareImpl), address(this), address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);

        memeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        // v3.3 permissionless creation: team-curation levers must be set before pool creation.
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        vault.approveRwaFeed(address(feed), "test RWA feed");
        memeId = vault.createBaseLimitPool(memeKey, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME", "M");

        rwaKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(hookAddr)
        });
        rwaId = vault.createBaseLimitPool(rwaKey, FeraTypes.Regime.RWA, address(feed), SQRT_PRICE_1_1, true, "RWA", "R");

        positions[0] = Pos(memeId, 0); // MEME Steady tranche
        positions[1] = Pos(rwaId, 0); // RWA Steady tranche
        positions[2] = Pos(rwaId, 1); // RWA Active tranche

        _fund(refHolder, 50_000e18);
        foreign[0] = makeAddr("foreignA");
        foreign[1] = makeAddr("foreignB");
        _fund(foreign[0], 50_000e18);
        _fund(foreign[1], 50_000e18);

        // Reference seeds every position (measures value actually consumed).
        for (uint256 i; i < 3; ++i) {
            refIn += _depositMeasured(refHolder, positions[i], SEED, SEED);
        }
    }

    function _fund(address who, uint256 amt) internal {
        MockERC20(Currency.unwrap(currency0)).transfer(who, amt);
        MockERC20(Currency.unwrap(currency1)).transfer(who, amt);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _bal(address who) internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(Currency.unwrap(currency0)).balanceOf(who);
        b1 = IERC20(Currency.unwrap(currency1)).balanceOf(who);
    }

    function _depositMeasured(address who, Pos memory p, uint256 a0, uint256 a1) internal returns (uint256 valueIn) {
        (uint256 b0, uint256 b1) = _bal(who);
        vm.prank(who);
        vault.deposit(p.id, p.t, a0, a1, 0);
        (uint256 m0, uint256 m1) = _bal(who);
        valueIn = (b0 - m0) + (b1 - m1);
    }

    function _withdrawAllMeasured(address who, Pos memory p) internal returns (uint256 valueOut) {
        IERC20 share = IERC20(vault.shareToken(p.id, p.t));
        uint256 bal = share.balanceOf(who);
        if (bal == 0) return 0;
        (uint256 b0, uint256 b1) = _bal(who);
        QW.drain(vault, p.id, p.t, bal, 0, 0, who); // request → warp WITHDRAW_DELAY_SEC → claim (in-kind)
        (uint256 m0, uint256 m1) = _bal(who);
        valueOut = (m0 - b0) + (m1 - b1);
    }

    // ── one guarded action, decoded from a seed ──────────────────────────────────────────────
    function _step(uint256 seed) internal {
        uint256 op = seed % 7;
        address actor = foreign[(seed >> 8) % 2];
        Pos memory pos = positions[(seed >> 16) % 3];
        uint256 amt = bound((seed >> 24), 1e18, 3_000e18);

        if (op == 0 || op == 1) {
            // foreign deposit (may fail-closed on a stale TWAP after long warps — guarded)
            (uint256 b0, uint256 b1) = _bal(actor);
            _foreignDeposit(actor, pos, amt, b0, b1);
        } else if (op == 2) {
            // foreign full-exit of a position it holds (after its cooldown)
            vm.warp(block.timestamp + COOLDOWN + 1);
            uint256 out = _foreignWithdraw(actor, pos);
            ghostForeignOut += out;
        } else if (op == 3) {
            try vault.skimIdle(pos.id, pos.t) {} catch {}
        } else if (op == 4) {
            try vault.collectFees(pos.id, pos.t) {} catch {}
        } else if (op == 5) {
            vm.warp(block.timestamp + FeraConstants.RWA_MIN_REBALANCE_INTERVAL_SEC + 1);
            try vault.rebalanceLimit(memeId, 0) {} catch {}
            try vault.rebalanceLimit(rwaId, 0) {} catch {}
        } else {
            vm.warp(block.timestamp + bound(seed, 1, 1_800));
        }
    }

    function _foreignDeposit(address actor, Pos memory pos, uint256 amt, uint256 b0Before, uint256 b1Before) internal {
        // Re-attempt as the actor so the deposit is attributed correctly; measure value consumed.
        vm.prank(actor);
        try vault.deposit(pos.id, pos.t, amt, amt, 0) {
            (uint256 m0, uint256 m1) = _bal(actor);
            ghostForeignIn += (b0Before - m0) + (b1Before - m1);
        } catch {}
    }

    function _foreignWithdraw(address actor, Pos memory pos) internal returns (uint256 out) {
        IERC20 share = IERC20(vault.shareToken(pos.id, pos.t));
        uint256 bal = share.balanceOf(actor);
        if (bal == 0) return 0;
        (uint256 b0, uint256 b1) = _bal(actor);
        // Universal async redemption (guarded): request (may revert on cooldown) → delay → claim.
        vm.prank(actor);
        share.approve(address(vault), bal);
        vm.prank(actor);
        try vault.requestWithdraw(pos.id, pos.t, bal, 0, 0) returns (uint256 rid) {
            vm.warp(block.timestamp + QW.DELAY);
            try vault.claimWithdraw(rid) {
                (uint256 m0, uint256 m1) = _bal(actor);
                out = (m0 - b0) + (m1 - b1);
            } catch {}
        } catch {}
    }

    /// @notice A refHolder holder that seeded every tranche is NEITHER diluted NOR enriched-at-others'-
    ///         expense by any interleaving of foreign deposits/withdraws and keeper strategy actions
    ///         (skimIdle / rebalanceLimit / collectFees) — swap-free, so NAV is conserved.
    function testFuzz_multiBandTranche_navConserved(uint256[10] calldata seeds) public {
        for (uint256 i; i < seeds.length; ++i) {
            _step(seeds[i]);
        }

        // Reference exits everything (withdrawals are never gated — INV-11).
        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 refOut;
        for (uint256 i; i < 3; ++i) {
            refOut += _withdrawAllMeasured(refHolder, positions[i]);
        }

        // Non-dilution: the refHolder recovers essentially its full deposit. The only permitted loss is
        // rounding + the per-first-deposit MINIMUM_LIQUIDITY dust (three positions × 1000 wei), which is
        // negligible against a 6_000e18 deposit ⇒ a 5bp floor is comfortable.
        assertGe(refOut, (refIn * 9_995) / 10_000, "INV-16: refHolder holder was diluted");
        // No skim: with no fees, the refHolder cannot recover MORE than it deposited (that would mean it
        // extracted value from foreign holders). Allow a wei of rounding slack.
        assertLe(refOut, refIn + 1e12, "refHolder extracted value from other holders");

        // No value created for foreigners either: with no fees, total withdrawn ≤ total deposited.
        assertLe(ghostForeignOut, ghostForeignIn + 1e12, "foreign actors created value from nothing");
    }
}
