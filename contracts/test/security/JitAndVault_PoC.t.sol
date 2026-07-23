// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FeraVault} from "../../src/FeraVault.sol";
import {FeraHook} from "../../src/FeraHook.sol";
import {FeraShare} from "../../src/shares/FeraShare.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {IFeraVault} from "../../src/interfaces/IFeraVault.sol";
import {IFeraShare} from "../../src/interfaces/IFeraShare.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice SECURITY AGENT 6 — D-M10 (JIT fee-forfeiture attacks), V2-3 (vault self-JIT leak),
///         and V2-2 (deposit cooldown share-transfer evasion). One harness: Vault + FeraHook +
///         real v4 PoolManager + routers.
contract JitAndVaultPoCTest is Deployers {
    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;

    PoolKey internal pk;
    PoolId internal id;

    int24 internal constant LO = -600;
    int24 internal constant HI = 600;
    uint256 internal constant WINDOW = 1800; // MEME JIT window
    uint256 internal constant COOLDOWN = 3600;
    uint256 internal constant T0 = 10_000_000;

    address internal honest = makeAddr("honest");
    address internal attacker = makeAddr("attacker");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x3B17) << 14));
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), IAnchorStaking(address(0)), address(shareImpl), address(this), address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);

        pk = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        // v3.3 permissionless creation: team-curation lever must be set before pool creation.
        vault.setAllowedQuoteAsset(Currency.unwrap(currency0), true);
        id = vault.createBaseLimitPool(pk, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME", "M");

        _fund(honest, 1_000e18);
        _fund(attacker, 1_000e18);
        _fund(bob, 1_000e18);
    }

    function _fund(address who, uint256 amt) internal {
        MockERC20(Currency.unwrap(currency0)).transfer(who, amt);
        MockERC20(Currency.unwrap(currency1)).transfer(who, amt);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _modify(int24 lo, int24 hi, int256 dL, bytes32 salt) internal returns (BalanceDelta d) {
        d = modifyLiquidityRouter.modifyLiquidity(
            pk, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: dL, salt: salt}), ""
        );
    }

    function _forfeited(Vm.Log[] memory logs) internal pure returns (uint256 f0, uint256 f1, uint256 count) {
        bytes32 topic = keccak256("JitPenaltyApplied(bytes32,address,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) {
                (uint256 a, uint256 b) = abi.decode(logs[i].data, (uint256, uint256));
                f0 += a;
                f1 += b;
                ++count;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // D-M10 (1) — SPLIT-POSITION dodge: splitting the JIT add across many salts gives NO advantage.
    // Each sub-position carries its own window and forfeits its own fees at elapsed 0.
    // ═══════════════════════════════════════════════════════════════════════════════════════
    function test_DM10_splitPositionDodge_noAdvantage() public {
        // Honest tail so a donation recipient always exists.
        _modify(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(1e15), "tail");
        vm.warp(T0 + WINDOW + 1);

        // Single position baseline: add L, swap, remove same-block -> forfeits ~100% of accrued.
        uint256 start = block.timestamp;
        BalanceDelta a1 = _modify(LO, HI, int256(4_000e18), "single");
        swap(pk, true, -20e18, "");
        vm.recordLogs();
        BalanceDelta r1 = _modify(LO, HI, -int256(4_000e18), "single");
        (uint256 sf0,,) = _forfeited(vm.getRecordedLogs());

        // Split across 4 salts, same total L, same swap, all removed same-block.
        vm.warp(start); // reset time so both scenarios are elapsed 0
        int256 each = int256(1_000e18);
        _modify(LO, HI, each, "s0");
        _modify(LO, HI, each, "s1");
        _modify(LO, HI, each, "s2");
        _modify(LO, HI, each, "s3");
        swap(pk, true, -20e18, "");
        vm.recordLogs();
        _modify(LO, HI, -each, "s0");
        _modify(LO, HI, -each, "s1");
        _modify(LO, HI, -each, "s2");
        _modify(LO, HI, -each, "s3");
        (uint256 pf0, uint256 pf1, uint256 pn) = _forfeited(vm.getRecordedLogs());

        emit log_named_uint("single-position forfeit token0", sf0);
        emit log_named_uint("split (4x) total forfeit token0", pf0);
        emit log_named_uint("split forfeit-event count", pn);
        // Splitting produces 4 independent penalty events; the aggregate forfeit is NOT reduced —
        // in fact sequential in-window exits re-forfeit each other's donations (a CASCADE), so the
        // splitter forfeits AT LEAST as much as a single position. No dodge; strictly worse.
        assertEq(pn, 4, "each split sub-position forfeits independently");
        assertGe(pf0, (sf0 * 99) / 100, "split REDUCED forfeiture (dodge found!)");
        pf1;
        a1;
        r1;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // D-M10 (2) — PATIENT SNIPER: waiting out the full window keeps the fee (penalty 0). Confirms
    // the accepted residual (D-M10 +$189) — the sniper carried WINDOW-length inventory risk.
    // ═══════════════════════════════════════════════════════════════════════════════════════
    function test_DM10_patientSniper_keepsFeeAfterWindow() public {
        _modify(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(1e15), "tail");
        vm.warp(T0 + WINDOW + 1);

        _modify(LO, HI, int256(4_000e18), "snipe");
        // The snipe must sit in-range for the whole window BEFORE the flow it wants to capture.
        vm.warp(block.timestamp + WINDOW + 1);
        swap(pk, true, -50e18, "");
        vm.recordLogs();
        BalanceDelta r = _modify(LO, HI, -int256(4_000e18), "snipe");
        (,, uint256 n) = _forfeited(vm.getRecordedLogs());
        assertEq(n, 0, "no penalty outside window (expected accepted residual)");
        assertGt(r.amount0(), int128(0), "sniper exits with principal + kept fee");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // D-M10 (3) — DONATION mechanics: `donate` distributes to in-range liquidity AT THE FORFEIT
    // INSTANT (the forfeiter's own liquidity is already removed). With committed liquidity present
    // (the Vault's tail band models exactly this), a 1-wei dust position captures ~0. FINDING
    // (documented, bounded): if in-range liquidity is THIN, or an attacker JITs a large in-range
    // position around a predictable forfeiture, they capture the donation — the mirror of JIT,
    // bounded by the same window. The tail band is the load-bearing mitigation.
    // ═══════════════════════════════════════════════════════════════════════════════════════
    function test_DM10_donationGoesProRataToInRange_dustCapturesNothing() public {
        // Committed in-range liquidity (models the Vault's always-in-range tail band).
        _modify(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(1e18), "committed");
        vm.warp(T0 + WINDOW + 1); // let the committed LP's window lapse

        // Attacker parks a 1-wei-liquidity in-range position.
        _modify(LO, HI, int256(1e9), "dust");
        // Victim JIT: add, swap, remove same-block -> full forfeit donated to in-range recipients.
        _modify(LO, HI, int256(4_000e18), "victim");
        swap(pk, true, -20e18, "");
        vm.recordLogs();
        BalanceDelta rv = _modify(LO, HI, -int256(4_000e18), "victim");
        (uint256 f0,, uint256 n) = _forfeited(vm.getRecordedLogs());
        assertEq(n, 1, "victim forfeits");
        assertGt(f0, 0, "forfeit nonzero");
        assertGt(rv.amount0(), int128(0), "removal did not revert (INV-1'')");

        // Dust captures ~0 because the committed tail dominates in-range liquidity pro-rata.
        vm.warp(block.timestamp + WINDOW + 1);
        BalanceDelta rd = _modify(LO, HI, -int256(1e9), "dust");
        emit log_named_int("dust position payout token0 (should be ~0)", rd.amount0());
        assertLt(uint256(int256(rd.amount0())), f0 / 1_000_000, "1-wei position captured a meaningful donation share");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // D-M10 (4) — removal NEVER reverts at any elapsed, even with a hostile withheld/penalty state.
    // ═══════════════════════════════════════════════════════════════════════════════════════
    function testFuzz_DM10_removalNeverReverts(uint256 wait, uint256 sw) public {
        _modify(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(1e15), "tail");
        vm.warp(T0 + WINDOW + 1);
        wait = bound(wait, 0, 2 * WINDOW);
        sw = bound(sw, 1e18, 40e18);
        _modify(LO, HI, int256(2_000e18), "fz");
        swap(pk, true, -int256(sw), "");
        vm.warp(block.timestamp + wait);
        BalanceDelta d = _modify(LO, HI, -int256(2_000e18), "fz"); // must never revert
        assertGt(d.amount0() + d.amount1(), int128(0), "principal did not exit");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // V2-3 — VAULT SELF-JIT leak to a direct LP. A user deposit re-arms the VAULT's band windows;
    // a withdrawal inside that window forfeits since-checkpoint fees, donated to in-range LPs. The
    // Vault is usually the majority (self-rebate); an external direct LP captures its liquidity
    // share of the forfeiture. We MEASURE the forfeited amount and the external-capture fraction.
    // ═══════════════════════════════════════════════════════════════════════════════════════
    function test_V23_vaultSelfJit_leakToDirectLP_bounded() public {
        // Vault honest deposit -> vault bands minted, vault windows armed at T0.
        vm.prank(honest);
        uint256 hShares = vault.deposit(id, 0, 200e18, 200e18, 0);

        // A direct LP co-locates a MODEST in-range position (10% scale) to farm the donations.
        _modify(LO, HI, int256(200e18), "directLP");

        // Flow accrues fees to both the vault bands and the direct LP.
        for (uint256 i; i < 8; ++i) {
            swap(pk, true, -3e18, "");
            swap(pk, false, -3e18, "");
        }

        // Honest cooldown lapses (3600 > vault window 1800).
        vm.warp(T0 + COOLDOWN);
        // Bob's deposit RE-ARMS the vault's band windows (positions keyed to the Vault owner) and
        // checkpoints (sweeping accrued fees to `pending`).
        vm.prank(bob);
        vault.deposit(id, 0, 1e18, 1e18, 0);

        // FRESH flow after the re-arm accrues new, un-checkpointed fees INSIDE the window — this is
        // the only slice exposed to the self-JIT leak (the checkpoint-before-mint discipline sweeps
        // everything older). Same block ⇒ elapsed≈0 ⇒ ~full forfeiture of this slice.
        for (uint256 i; i < 6; ++i) {
            swap(pk, true, -3e18, "");
            swap(pk, false, -3e18, "");
        }

        // Honest withdraws HALF inside the freshly re-armed vault window -> forfeiture fires on the
        // vault's own band poke/removals, donated to in-range LPs (vault remainder + the direct LP).
        vm.recordLogs();
        vm.prank(honest);
        vault.withdraw(id, 0, hShares / 2, 0, 0);
        (uint256 f0, uint256 f1, uint256 n) = _forfeited(vm.getRecordedLogs());

        emit log_named_uint("V2-3 forfeit events during vault withdraw", n);
        emit log_named_decimal_uint("V2-3 forfeited token0 (donated to in-range)", f0, 18);
        emit log_named_decimal_uint("V2-3 forfeited token1 (donated to in-range)", f1, 18);

        // The forfeited amount is bounded by fees accrued since the last vault checkpoint (the vault
        // checkpoints on EVERY deposit), and only the direct-LP in-range fraction leaks; the rest
        // self-rebates to the vault's remaining in-range bands. Principal is untouched: honest still
        // received its half.
        // Direct LP in-range share ≈ 200e18 / (vault in-range + 200e18). Report it as the leak bound.
        assertLt(f0 + f1, 5e18, "forfeiture unexpectedly large vs since-checkpoint fees");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // V2-2 — the deposit COOLDOWN evasion (transfer fresh shares to a second wallet) is now BLOCKED
    // by the per-account share-transfer lock on FeraShare (SEC-3 #4). The lock is set to
    // block.timestamp + DEPOSIT_COOLDOWN_SEC on every deposit; outgoing transfers revert until it
    // lapses, so the 1h hold can no longer be side-stepped by moving shares.
    // ═══════════════════════════════════════════════════════════════════════════════════════
    function test_V22_cooldownEvasion_viaShareTransfer() public {
        // seed so it is not a first deposit
        vm.prank(honest);
        vault.deposit(id, 0, 100e18, 100e18, 0);

        // OD-24: non-first deposits require the pool to be past the shallow-oracle-history window.
        vm.warp(block.timestamp + FeraConstants.DEPOSIT_TWAP_WINDOW_SEC + 1);
        vm.prank(attacker);
        uint256 aShares = vault.deposit(id, 0, 50e18, 50e18, 0);

        IFeraShare share = IFeraShare(vault.shareToken(id, 0));

        // Attacker's OWN withdraw is cooldown-blocked...
        vm.prank(attacker);
        vm.expectRevert(IFeraVault.CooldownActive.selector);
        vault.withdraw(id, 0, aShares, 0, 0);

        // ...and the evasion route is now closed: transferring the fresh shares REVERTS while the
        // deposit cooldown is active (V2-2 patch). The cooldown can no longer be dodged.
        vm.prank(attacker);
        vm.expectRevert(IFeraShare.TransferLocked.selector);
        share.transfer(bob, aShares);

        // After the cooldown lapses the transfer (and a normal withdraw) work again.
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(attacker);
        share.transfer(bob, aShares);
        vm.prank(bob);
        (uint256 out0, uint256 out1) = vault.withdraw(id, 0, aShares, 0, 0);
        assertGt(out0 + out1, 0, "post-cooldown transfer+withdraw should succeed");
        emit log("V2-2: 1h deposit cooldown transfer-evasion BLOCKED (share-transfer lock)");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Finding-3 (v3.5), CORRECTED (audit finding, open-kritt): an EARLIER version of this fix had
    // `deposit()` skip arming FeraShare.transferLockUntil for a `cooldownExempt` address ENTIRELY,
    // so its fresh shares were transferable the instant the exemption was granted — which is what
    // `emergencyRedeemInKind` (a raw `FeraShare.transfer`, not `burn`) needs. But skipping the lock
    // entirely let an exempt address transfer freshly-minted shares to a throwaway wallet for an
    // INSTANT, zero-wait withdrawal (the recipient's own lastDepositTs/depositClock is 0, trivially
    // satisfying the withdraw cooldown for any real block.timestamp) — defeating Finding-2's floor
    // via a transfer side-channel. The CORRECT fix arms a SHORTER (not zero) lock at the SAME
    // JIT-window-plus-margin floor `_exemptWithdrawFloorSec` already uses for withdrawals: the
    // exemption still shortens the wait `emergencyRedeemInKind` needs (vs. the full
    // DEPOSIT_COOLDOWN_SEC a normal depositor waits), but by the time ANY transfer of these shares
    // becomes possible, the JIT-sensitive window has already closed, so an immediate post-transfer
    // withdrawal is safe by construction. THREAT_MODEL.md §10.2's v3.5 addendum needs a matching
    // correction to this doc claim.
    // ═══════════════════════════════════════════════════════════════════════════════════════
    function test_cooldownExempt_armsShorterTransferLock_nonExemptStillFullyLocked() public {
        address indexVault = makeAddr("indexVault");
        _fund(indexVault, 1_000e18);
        vault.setCooldownExempt(indexVault, true);

        // seed so it is not a first deposit
        vm.prank(honest);
        vault.deposit(id, 0, 100e18, 100e18, 0);

        // OD-24: non-first deposits require the pool to be past the shallow-oracle-history window.
        vm.warp(block.timestamp + FeraConstants.DEPOSIT_TWAP_WINDOW_SEC + 1);

        IFeraShare share = IFeraShare(vault.shareToken(id, 0));
        uint256 exemptFloor = FeraConstants.JIT_PENALTY_WINDOW_MEME + FeraConstants.EXEMPT_WITHDRAW_MARGIN_SEC;

        // Exempt address: deposit arms a SHORTER (not zero) lock.
        vm.prank(indexVault);
        uint256 exemptShares = vault.deposit(id, 0, 50e18, 50e18, 0);
        assertEq(
            share.transferLockUntil(indexVault),
            block.timestamp + exemptFloor,
            "exempt address must have a SHORTER, non-zero transfer lock armed"
        );

        // ...so an immediate transfer still reverts, unlike the pre-fix "never armed" behavior.
        vm.prank(indexVault);
        vm.expectRevert(IFeraShare.TransferLocked.selector);
        share.transfer(bob, exemptShares);

        // Once the shorter floor clears, the transfer succeeds -- by then the JIT-sensitive window
        // has already closed, so this is exactly what emergencyRedeemInKind needs, safely.
        vm.warp(block.timestamp + exemptFloor);
        vm.prank(indexVault);
        share.transfer(bob, exemptShares);
        assertEq(share.balanceOf(bob), exemptShares, "exempt address's shares must be transferable once its shorter floor clears");

        // Non-exempt address, same block: deposit still arms the FULL lock (contrast) — the
        // exemption is narrow and per-address, not a global relaxation of V2-2's evasion fix.
        vm.prank(attacker);
        uint256 nonExemptShares = vault.deposit(id, 0, 50e18, 50e18, 0);
        assertGt(
            share.transferLockUntil(attacker), block.timestamp, "non-exempt deposit must still arm the FULL transfer lock"
        );

        vm.prank(attacker);
        vm.expectRevert(IFeraShare.TransferLocked.selector);
        share.transfer(bob, nonExemptShares);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // v3.5.1 (audit finding, medium) — `cooldownExempt`'s withdraw floor (`_exemptWithdrawFloorSec`)
    // is anchored ONLY to the exempt address's OWN `lastDepositTs`. It fully closes THAT address's
    // own deposit-then-instantly-withdraw round trip (Finding-2), but `FeraHook`'s JIT clock is keyed
    // per (pool, tranche, band) — SHARED across every depositor and the keeper, not per-depositor.
    // This proves the pre-fix NatSpec's "this floor closes that" / "restores that same guarantee"
    // language overclaimed: an exempt address that waits out its OWN floor can still have its
    // withdraw-time checkpoint forfeit fees because a DIFFERENT depositor's ordinary ratio-mint
    // re-armed the same band afterward — the exact V2-3 "Vault self-interaction" residual
    // (THREAT_MODEL.md §10.1), just reachable at the exempt address's shorter floor instead of the
    // full DEPOSIT_COOLDOWN_SEC. This is a documentation/NatSpec fix (see FeraVault.sol's
    // `cooldownExempt` NatSpec and FeraConstants.sol's `EXEMPT_WITHDRAW_MARGIN_SEC` NatSpec, plus
    // THREAT_MODEL.md's new v3.5.1 addendum) -- the mechanism itself is the SAME already-accepted,
    // bounded, fee-only V2-3 residual, so this test passes both before and after that doc fix; it
    // exists to pin the real behavior the corrected NatSpec now describes, and to guard against a
    // future "fix" that quietly re-introduces the false guarantee without addressing this residual.
    // ═══════════════════════════════════════════════════════════════════════════════════════
    function test_cooldownExempt_floorDoesNotProtect_againstThirdPartyReArm() public {
        address indexVault = makeAddr("indexVault");
        _fund(indexVault, 1_000e18);
        vault.setCooldownExempt(indexVault, true);

        // Seed so it is not a first deposit.
        vm.prank(honest);
        vault.deposit(id, 0, 200e18, 200e18, 0);

        // OD-24: non-first deposits require the pool to be past the shallow-oracle-history window.
        vm.warp(block.timestamp + FeraConstants.DEPOSIT_TWAP_WINDOW_SEC + 1);

        // indexVault deposits -- arms BOTH its own `lastDepositTs` (the exempt floor's anchor) AND
        // the shared per-band JIT clock (the same bands honest already minted into).
        vm.prank(indexVault);
        uint256 shares = vault.deposit(id, 0, 100e18, 100e18, 0);

        // Ordinary fee-generating flow.
        for (uint256 i; i < 4; ++i) {
            swap(pk, true, -2e18, "");
            swap(pk, false, -2e18, "");
        }

        // Wait out indexVault's OWN exempt floor: regime JIT window + margin, past ITS OWN deposit.
        // Per the pre-fix NatSpec ("this floor closes that" / "restores that same guarantee") this
        // should be enough for indexVault to withdraw clear of any JIT-forfeiture window.
        vm.warp(block.timestamp + FeraConstants.JIT_PENALTY_WINDOW_MEME + FeraConstants.EXEMPT_WITHDRAW_MARGIN_SEC + 1);

        // A THIRD PARTY's ordinary, honest, ratio-matched deposit into the SAME tranche re-arms the
        // SHARED band clock. indexVault's own floor computation (anchored only to its OWN deposit)
        // never sees this -- and never could, by construction.
        vm.prank(bob);
        vault.deposit(id, 0, 5e18, 5e18, 0);

        // Fresh flow lands INSIDE the window bob's deposit just (re)armed.
        for (uint256 i; i < 4; ++i) {
            swap(pk, true, -2e18, "");
            swap(pk, false, -2e18, "");
        }

        // indexVault's OWN floor is satisfied (it waited well past its own deposit) -- withdraw
        // succeeds (never blocked, INV-1''/INV-11), but its mandatory checkpoint pokes bands that
        // are still inside the window BOB armed a moment ago, and forfeits.
        vm.recordLogs();
        vm.prank(indexVault);
        vault.withdraw(id, 0, shares, 0, 0);
        (uint256 f0, uint256 f1, uint256 n) = _forfeited(vm.getRecordedLogs());

        emit log_named_uint("exempt withdraw forfeit events despite satisfied exempt floor", n);
        emit log_named_decimal_uint("exempt withdraw forfeited token0", f0, 18);
        emit log_named_decimal_uint("exempt withdraw forfeited token1", f1, 18);
        assertGt(n, 0, "expected a JIT forfeiture even though indexVault's own exempt floor had elapsed");
        assertGt(f0 + f1, 0, "expected nonzero forfeited fees from the third-party-armed window");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // R-12 — first-depositor / donation inflation is DEFUSED (MINIMUM_LIQUIDITY lock + liquidity-
    // based share price). A raw token donation to the Vault does not move share price.
    // ═══════════════════════════════════════════════════════════════════════════════════════
    function test_R12_firstDepositorInflation_defused() public {
        IFeraShare share = IFeraShare(vault.shareToken(id, 0));

        // (1) Attacker CANNOT open a 1-share-worth-everything pool: a first deposit whose minted
        //     ladder liquidity is <= MINIMUM_LIQUIDITY reverts (the classic inflation precondition).
        vm.prank(attacker);
        vm.expectRevert(bytes("min-liq"));
        vault.deposit(id, 0, 1, 1, 0);

        // (2) A normal first deposit locks MINIMUM_LIQUIDITY to dEaD.
        vm.prank(honest);
        uint256 s1 = vault.deposit(id, 0, 100e18, 100e18, 0);
        assertEq(share.balanceOf(0x000000000000000000000000000000000000dEaD), 1_000, "MINIMUM_LIQUIDITY not locked");

        // (3) Attacker donates a large raw balance directly to the Vault (classic inflation attempt).
        vm.prank(attacker);
        MockERC20(Currency.unwrap(currency0)).transfer(address(vault), 500e18);

        // (4) The next depositor still receives FAIR (proportional) shares — the donation neither
        //     inflates the share price nor is it claimable (share value tracks banded liquidity +
        //     pending + reserve, never the raw balance; the 500e18 is stranded, THREAT_MODEL §3).
        // OD-24: non-first deposits require the pool to be past the shallow-oracle-history window.
        vm.warp(block.timestamp + FeraConstants.DEPOSIT_TWAP_WINDOW_SEC + 1);
        vm.prank(bob);
        uint256 s2 = vault.deposit(id, 0, 100e18, 100e18, 0);
        assertApproxEqRel(s2, s1, 0.01e18, "donation inflated/deflated the share price (R-12 broken)");
        emit log_named_uint("depositor 1 shares", s1);
        emit log_named_uint("depositor 2 shares (post-donation, must match)", s2);
    }
}
