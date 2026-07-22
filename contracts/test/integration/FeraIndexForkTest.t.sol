// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeraVault} from "../../src/FeraVault.sol";
import {FeraIndexVault} from "../../src/FeraIndexVault.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {IFeraVault} from "../../src/interfaces/IFeraVault.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mainnet-fork integration for FeraIndexVault against the 5 LIVE FERA pools on Robinhood
///         Chain (addresses from frontend/config/pools.ts, snapshot 2026-07-17/18). GATED on the
///         `RH_FORK_URL` env var — if unset the test is skipped, so CI without network access stays
///         green (the deterministic coverage lives in FeraIndexVault.t.sol; this only exercises the
///         REAL curated pools end-to-end).
///
/// @dev Two assumptions the run will loudly assert if wrong (both cheap to fix): the member pools
///      are dynamic-fee with `tickSpacing == 60` (the MEME default), and the memecoins are 18-dec.
///      If a pool used a different tickSpacing at creation, `key.toId()` will not equal the live
///      `poolId`, `_curated` will fail, and this test points at the exact member to fix.
contract FeraIndexForkTest is Test {
    // ── Live registry (frontend/config/pools.ts) ────────────────────────────────────────────────
    address internal constant VAULT = 0xa8cF82797ecBC8C5cD5F83D60e189dbDc88D959a;
    address internal constant HOOK = 0x96CE193F25db9b75743332bB7C94e545f1a225C3;
    address internal constant WWETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    uint256 internal constant N = 5;
    address[N] internal memecoins = [
        0x45242320DBB855EeA8Fd36804C6487E10E97FCF9, // TENDIES
        0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31, // VIRTUAL
        0x7e86381A763F0Ecca2bDF27C54eAC403ddD48123, // GME
        0x0339f5459FC690aC85F1782e15782A151b4A9E1b, // WALLET
        0x39dBED3a2bd333467115dE45665cC57F813C4571 // PONS
    ];
    bytes32[N] internal poolIds = [
        bytes32(0x781f4bd64678be81a559f58bb124c570fb86abc04831f1c41212984340df9a12),
        bytes32(0x4412b3443d6f50184af006e8e0fa2573ef0b7ef7ddb675738971311a27236ef7),
        bytes32(0x848c3b7e44feed741b097eecba7846dd96414e8b1fc21488c71c8b9bcb115cb5),
        bytes32(0x877c04e865fffdfb450a86e5d1c3e5892ea56d5e33e3d56733249330a5b234b3),
        bytes32(0x4f382e3ceda365063d6824280583f2c485fe4f5c21178c39901c45f11a47e44d)
    ];

    FeraIndexVault internal index;
    IPoolManager internal manager;
    bool internal active;

    function setUp() public {
        string memory url = vm.envOr("RH_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            emit log("RH_FORK_URL unset - skipping the live-pool fork integration");
            return;
        }
        try vm.createSelectFork(url) {
            active = true;
        } catch {
            emit log("fork RPC unreachable - skipping the live-pool fork integration");
            return;
        }

        manager = FeraVault(VAULT).poolManager();

        index = new FeraIndexVault(
            WWETH, manager, IFeraHook(HOOK), IFeraVault(VAULT), address(this), address(this), "FERA Index", "fIDX"
        );

        PoolKey[] memory keys = new PoolKey[](N);
        uint16[] memory weights = new uint16[](N);
        for (uint256 i; i < N; ++i) {
            keys[i] = _liveKey(i);
            require(PoolId.unwrap(keys[i].toId()) == poolIds[i], "tickSpacing/fee guess != live poolId - see NatSpec");
            weights[i] = 2_000; // equal weight
        }
        index.setMembers(keys, weights);
    }

    /// Reconstruct a live pool's key: (wWETH, memecoin) sorted, dynamic fee, tickSpacing 60, FERA hook.
    function _liveKey(uint256 i) internal view returns (PoolKey memory) {
        bool q0 = WWETH < memecoins[i];
        (Currency c0, Currency c1) =
            q0 ? (Currency.wrap(WWETH), Currency.wrap(memecoins[i])) : (Currency.wrap(memecoins[i]), Currency.wrap(WWETH));
        return PoolKey({currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(HOOK)});
    }

    function test_fork_liveBasket_depositWithdraw_roundTripBounded() public {
        if (!active) return; // skipped (no fork)

        // Small deposit to keep price impact well under the depth cap on real liquidity.
        uint256 amount = 1e16; // 0.01 wWETH
        deal(WWETH, address(this), amount);
        IERC20(WWETH).approve(address(index), type(uint256).max);

        uint256 before = IERC20(WWETH).balanceOf(address(this));
        uint256 shares = index.deposit(amount, 0);
        assertGt(shares, 0, "no index shares minted from the live basket");

        // Every live member leg was acquired.
        for (uint256 i; i < N; ++i) {
            assertGt(index.memberValue(PoolId.wrap(poolIds[i])), 0, "a live member leg is empty");
        }

        // Round trip past the vault cooldown returns no more than deposited (INV-I1) on real pools.
        vm.warp(block.timestamp + 3_600 + 1);
        uint256 out = index.withdraw(shares, 0);
        uint256 spent = before - IERC20(WWETH).balanceOf(address(this)) + out;
        assertLe(out, amount, "INV-I1 violated on the live basket");
        assertLe(spent, amount, "spent more than deposited");
    }
}
