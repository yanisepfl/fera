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
import {MockAggregatorV3, MintableERC20} from "../utils/Mocks.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice v3.3 PERMISSIONLESS POOL CREATION (contracts/VAULT_STRATEGY_V3.md §11 — the decided
///         spec's "permissionless pool creation with team-curated emissions" model). Covers the
///         exact TESTS matrix from the decided spec:
///          1. permissionless MEME pool creation by a random address succeeds against an
///             allowlisted quote asset, and REVERTS against a non-allowlisted quote asset.
///          2. RWA pool creation REVERTS for an unapproved feed and succeeds once the team
///             approves it.
///          3. the emissions-eligible flag defaults false, is settable only by the admin, and a
///             non-eligible pool still correctly runs fee collection/routing/perf-fee splits —
///             proving eligibility and fee-generation are independent.
///          4. a malicious actor's fake/self-referential "quote" token (pretending to be liquid) is
///             rejected by the allowlist.
contract PermissionlessPoolCreationTest is Deployers {
    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;
    MockAggregatorV3 internal feed;

    address internal stakersAddr = makeAddr("stakers");
    address internal treasuryAddr = makeAddr("treasury");
    address internal opsAddr = makeAddr("ops");
    address internal randomCaller = makeAddr("randomCaller");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant T0 = 10_000_000;

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(stakersAddr, treasuryAddr, opsAddr);
        feed = new MockAggregatorV3(8);
        feed.set(1e8, T0);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0xFC01) << 14));
        // keeper == owner == this test contract (the "team"). Pool CREATION itself is
        // permissionless now (v3.3) — `keeper`/`owner` here only matter for the admin-curation
        // levers (setAllowedQuoteAsset/approveRwaFeed/setEmissionsEligible) this file exercises.
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), IAnchorStaking(address(0)), address(shareImpl), address(this), address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);

        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
    }

    function _memeKey(int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(address(hook))
        });
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 1) Permissionless MEME creation succeeds for a RANDOM caller against an allowlisted quote
    //    asset, and REVERTS against a non-allowlisted quote asset.
    // ═════════════════════════════════════════════════════════════════════════════════════
    function test_permissionlessMemeCreation_randomCaller_succeedsWithAllowlistedQuote() public {
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);

        vm.prank(randomCaller); // NOT the keeper, NOT the owner — a totally uninvolved address.
        PoolId id = vault.createBaseLimitPool(_memeKey(60), FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME", "M");

        assertEq(vault.trancheCount(id), 2, "permissionless creation must still build both tranches");
        assertEq(uint8(vault.regimeOf(id)), uint8(FeraTypes.Regime.MEME));
        assertFalse(vault.emissionsEligible(id), "emissions eligibility must default FALSE");
    }

    function test_permissionlessMemeCreation_revertsForNonAllowlistedQuoteAsset() public {
        // currency0 was NEVER allowlisted here — the team never called setAllowedQuoteAsset.
        vm.prank(randomCaller);
        vm.expectRevert(IFeraVault.QuoteAssetNotAllowed.selector);
        vault.createBaseLimitPool(_memeKey(60), FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME", "M");
    }

    /// @notice The allowlist check is keyed on the DESIGNATED quote side (`quoteIsToken0`), not on
    ///         token0 unconditionally — allowlisting currency1 as quote (quoteIsToken0=false) must
    ///         also work, and allowlisting the WRONG side must still revert.
    function test_permissionlessMemeCreation_quoteSideRespectsQuoteIsToken0Flag() public {
        vault.setAllowedQuoteAsset(Currency.unwrap(currency1), true); // only currency1 allowlisted

        // quoteIsToken0 = false ⇒ currency1 is the designated quote ⇒ succeeds.
        PoolId id = vault.createBaseLimitPool(_memeKey(60), FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, false, "MEME", "M");
        assertEq(vault.trancheCount(id), 2);

        // quoteIsToken0 = true ⇒ currency0 is the designated quote, which is NOT allowlisted ⇒ reverts.
        vm.expectRevert(IFeraVault.QuoteAssetNotAllowed.selector);
        vault.createBaseLimitPool(_memeKey(120), FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME2", "M2");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 2) RWA creation REVERTS for an unapproved feed and succeeds once the team approves it.
    // ═════════════════════════════════════════════════════════════════════════════════════
    function test_rwaCreation_revertsForUnapprovedFeed_succeedsOnceApproved() public {
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        PoolKey memory rwaKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        // Feed not yet approved ⇒ reverts, even for a MEME-quote-allowlisted pair.
        vm.prank(randomCaller);
        vm.expectRevert(IFeraVault.RwaFeedNotApproved.selector);
        vault.createBaseLimitPool(rwaKey, FeraTypes.Regime.RWA, address(feed), SQRT_PRICE_1_1, true, "RWA", "R");

        // A zero feed is likewise rejected for RWA (never treated as "unset ⇒ blind fee" the way
        // MEME's oracleFeed==0 is).
        vm.expectRevert(IFeraVault.RwaFeedNotApproved.selector);
        vault.createBaseLimitPool(rwaKey, FeraTypes.Regime.RWA, address(0), SQRT_PRICE_1_1, true, "RWA", "R");

        // Team approves the feed — now ANY caller (still permissionless) can bind to it.
        vault.approveRwaFeed(address(feed), "NVDA/USD test feed");
        vm.prank(randomCaller);
        PoolId rid = vault.createBaseLimitPool(rwaKey, FeraTypes.Regime.RWA, address(feed), SQRT_PRICE_1_1, true, "RWA", "R");
        assertEq(uint8(vault.regimeOf(rid)), uint8(FeraTypes.Regime.RWA));
    }

    function test_rwaFeedRegistry_onlyOwnerCanApprove() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(); // Ownable unauthorized
        vault.approveRwaFeed(address(feed), "should fail");
        assertFalse(vault.approvedRwaFeeds(address(feed)));
    }

    /// @notice MEME creation never consults the RWA feed registry at all — an unapproved (even
    ///         nonzero) feed address passed to a MEME pool is simply stored inertly (unused), never
    ///         gated. This matches item 2 of the decided spec ("MEME pool creation needs no such
    ///         registry — no oracle risk there").
    function test_memeCreation_neverConsultsRwaFeedRegistry() public {
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        // `feed` is deliberately NOT approved here.
        PoolId id = vault.createBaseLimitPool(_memeKey(60), FeraTypes.Regime.MEME, address(feed), SQRT_PRICE_1_1, true, "MEME", "M");
        assertEq(vault.trancheCount(id), 2, "MEME creation must not require RWA feed approval");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 3) emissions-eligible flag: defaults false, admin-only settable, and fee generation/routing
    //    is COMPLETELY INDEPENDENT of it.
    // ═════════════════════════════════════════════════════════════════════════════════════
    function test_emissionsEligible_defaultsFalse_onlyOwnerCanSet() public {
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        vm.prank(randomCaller);
        PoolId id = vault.createBaseLimitPool(_memeKey(60), FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME", "M");

        assertFalse(vault.emissionsEligible(id), "must default FALSE for a permissionlessly-created pool");

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(); // Ownable unauthorized
        vault.setEmissionsEligible(id, true);
        assertFalse(vault.emissionsEligible(id), "a non-owner call must not have changed the flag");

        vault.setEmissionsEligible(id, true); // owner (the team) — succeeds
        assertTrue(vault.emissionsEligible(id));

        vault.setEmissionsEligible(id, false); // team may also revoke it
        assertFalse(vault.emissionsEligible(id));
    }

    /// @notice The central independence property (item 3 / item 4 of the decided spec): a pool that
    ///         is NOT emissions-eligible still fully participates in fee generation and the
    ///         stage-2 unified fee-routing perf-fee split (staker/treasury/ops) — eligibility ONLY
    ///         ever affects off-chain esFERA emission attribution, nothing on-chain about revenue.
    function test_nonEligiblePool_stillRunsFeeCollectionAndPerfFeeSplit() public {
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        PoolKey memory key = _memeKey(60);
        vm.prank(randomCaller); // permissionlessly created — the team never even touched it
        PoolId id = vault.createBaseLimitPool(key, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME", "M");
        assertFalse(vault.emissionsEligible(id), "sanity: still not emissions-eligible");

        vault.deposit(id, 0, 500e18, 500e18, 0);

        // Generate real swap fees against the Vault's in-range base band.
        for (uint256 i; i < 6; ++i) {
            swap(key, true, -2e18, "");
            swap(key, false, -2e18, "");
        }
        vm.warp(block.timestamp + FeraConstants.JIT_PENALTY_WINDOW_MEME + 1);

        (uint256 fee0, uint256 fee1, uint256 perfFee0, uint256 perfFee1) = vault.collectFees(id, 0);
        assertGt(fee0 + fee1, 0, "no LP fees accrued - swap harness issue");
        assertGt(perfFee0 + perfFee1, 0, "no perf fee skimmed");

        // anchorStaking == address(0) here ⇒ legacy passthrough: BOTH sides routed directly via
        // notifyRevenue's 50/25/25 split (contracts/VAULT_STRATEGY_V3.md §9.5) — the SAME path an
        // emissions-eligible pool would use; the flag never enters this logic at all.
        address t0 = Currency.unwrap(currency0);
        address t1 = Currency.unwrap(currency1);
        uint256 stakersGot = rev.pending(stakersAddr, t0) + rev.pending(stakersAddr, t1);
        uint256 treasuryGot = rev.pending(treasuryAddr, t0) + rev.pending(treasuryAddr, t1);
        uint256 opsGot = rev.pending(opsAddr, t0) + rev.pending(opsAddr, t1);
        uint256 totalRouted = stakersGot + treasuryGot + opsGot;

        assertEq(totalRouted, perfFee0 + perfFee1, "INV-10: routed total must equal the perf fee exactly");
        assertGt(stakersGot, 0, "stakers must have received their 50% leg despite non-eligibility");
        assertGt(treasuryGot, 0, "treasury must have received its 25% leg despite non-eligibility");
        assertGt(opsGot, 0, "ops must have received its 25% leg despite non-eligibility");

        // The flag is STILL false — fee routing never touched it, and it never gates fee routing.
        assertFalse(vault.emissionsEligible(id), "fee collection/routing must never flip this flag");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 4) A malicious actor tries to create a pool with a fake/self-referential "quote" token
    //    pretending to be liquid — the allowlist rejects it regardless of how it's dressed up.
    // ═════════════════════════════════════════════════════════════════════════════════════
    function test_maliciousActor_fakeSelfReferentialQuoteToken_rejectedByAllowlist() public {
        // The attacker mints itself a huge "liquid-looking" supply of a brand-new token and names
        // it to look like a legitimate quote asset — none of this matters: it was never
        // team-allowlisted, so `createBaseLimitPool` must reject it regardless of appearance.
        vm.startPrank(attacker);
        MintableERC20 fakeQuote = new MintableERC20("Wrapped ETH", "WETH"); // deceptive name/symbol
        fakeQuote.mint(attacker, 1_000_000_000e18); // "deep liquidity" the attacker fully controls
        vm.stopPrank();

        MintableERC20 native = new MintableERC20("SCAM", "SCAM");
        bool fakeIsC0 = address(fakeQuote) < address(native);
        Currency c0 = fakeIsC0 ? Currency.wrap(address(fakeQuote)) : Currency.wrap(address(native));
        Currency c1 = fakeIsC0 ? Currency.wrap(address(native)) : Currency.wrap(address(fakeQuote));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(address(hook))});

        // Never allowlisted by the team ⇒ rejected, no matter the token's name/symbol/self-minted
        // "liquidity" — the allowlist is the ONLY thing that decides eligibility as a quote asset.
        vm.prank(attacker);
        vm.expectRevert(IFeraVault.QuoteAssetNotAllowed.selector);
        vault.createBaseLimitPool(key, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, fakeIsC0, "SCAM-LP", "sLP");

        assertFalse(vault.allowedQuoteAssets(address(fakeQuote)), "fake quote token must never be allowlisted");
    }

    function test_setAllowedQuoteAsset_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(); // Ownable unauthorized
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        assertFalse(vault.allowedQuoteAssets(Currency.unwrap(currency0)));
    }
}
