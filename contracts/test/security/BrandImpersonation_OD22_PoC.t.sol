// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FeraVault} from "../../src/FeraVault.sol";
import {FeraHook} from "../../src/FeraHook.sol";
import {FeraShare} from "../../src/shares/FeraShare.sol";
import {RevenueDistributor} from "../../src/RevenueDistributor.sol";
import {IFeraHook} from "../../src/interfaces/IFeraHook.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../../src/interfaces/IAnchorStaking.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev A token whose `symbol()` always reverts — models a hostile/broken ERC20 to prove
///      `VaultOps._tokenSymbol`'s try/catch degrades gracefully instead of bricking pool creation.
contract RevertingSymbolERC20 {
    function symbol() external pure returns (string memory) {
        revert("no symbol for you");
    }

    function name() external pure returns (string memory) {
        return "Reverting Token";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice OPEN_DECISIONS.md#OD-22 (MITIGATED 2026-07-23): `createBaseLimitPool` performs no
///         validation on caller-supplied `name_`/`symbol_`, so an attacker can front-run a
///         legitimate pool creation with a deceptive label (e.g. "USD Coin"/"USDC"). The mitigation
///         appends the pool's OWN on-chain token symbols (read via `IERC20Metadata`, never
///         caller-supplied) to the share name — this was previously only reasoned about verbally.
///         Proven here, matching the same fuzz rigor as OD-25: an adversarial `name_`/`symbol_`
///         (arbitrary fuzzed strings, not just a plausible-looking scam label) can NEVER prevent
///         the real underlying token symbols from appearing in the resulting share name, and a
///         hostile/broken token whose `symbol()` reverts can never brick pool creation.
contract BrandImpersonationOD22PoCTest is Deployers {
    FeraVault internal vault;
    FeraHook internal hook;
    RevenueDistributor internal rev;
    FeraShare internal shareImpl;

    MockERC20 internal real0;
    MockERC20 internal real1;

    function setUp() public {
        deployFreshManagerAndRouters();

        shareImpl = new FeraShare();
        rev = new RevenueDistributor(makeAddr("stakers"), makeAddr("treasury"), makeAddr("ops"));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x0D22) << 14));
        vault = new FeraVault(
            manager, IFeraHook(hookAddr), IRevenueDistributor(address(rev)), IAnchorStaking(address(0)), address(shareImpl), address(this), address(this)
        );
        deployCodeTo("FeraHook.sol:FeraHook", abi.encode(manager, address(vault)), hookAddr);
        hook = FeraHook(hookAddr);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return n.length == 0;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// @dev Real pair, real symbols "REAL0"/"REAL1" — sorted by address so currency0/currency1
    ///      match whatever v4 PoolKey ordering results.
    function _freshRealPair() internal {
        MockERC20 a = new MockERC20("Real Token A", "REAL0", 18);
        MockERC20 b = new MockERC20("Real Token B", "REAL1", 18);
        (real0, real1) = address(a) < address(b) ? (a, b) : (b, a);
    }

    /// @notice Fuzzes the ATTACKER'S chosen `name_`/`symbol_` over arbitrary strings (not just a
    ///         plausible scam label) — the real on-chain symbols must appear in the resulting share
    ///         name regardless of what the attacker tried to claim instead.
    function testFuzz_OD22_shareNameAlwaysExposesRealTokenSymbols(string memory attackerName, string memory attackerSymbol)
        public
    {
        vm.assume(bytes(attackerName).length <= 300);
        vm.assume(bytes(attackerSymbol).length <= 300);
        _freshRealPair();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(real0)),
            currency1: Currency.wrap(address(real1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vault.setAllowedQuoteAsset(address(real0), true);
        PoolId id = vault.createBaseLimitPool(key, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, attackerName, attackerSymbol);

        string memory shareName0 = IERC20Metadata(vault.shareToken(id, 0)).name();
        string memory shareName1 = IERC20Metadata(vault.shareToken(id, 1)).name();

        assertTrue(_contains(shareName0, "REAL0"), "tranche0: real token0 symbol missing from share name");
        assertTrue(_contains(shareName0, "REAL1"), "tranche0: real token1 symbol missing from share name");
        assertTrue(_contains(shareName1, "REAL0"), "tranche1: real token0 symbol missing from share name");
        assertTrue(_contains(shareName1, "REAL1"), "tranche1: real token1 symbol missing from share name");
    }

    /// @notice A hostile/broken underlying token whose `symbol()` always reverts must NEVER brick
    ///         pool creation — `_tokenSymbol`'s try/catch must degrade to a placeholder instead.
    function test_OD22_revertingTokenSymbol_fallsBackGracefully_neverBricksCreation() public {
        RevertingSymbolERC20 hostile = new RevertingSymbolERC20();
        MockERC20 real = new MockERC20("Real Token", "REAL0", 18);
        (address c0, address c1) =
            address(hostile) < address(real) ? (address(hostile), address(real)) : (address(real), address(hostile));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vault.setAllowedQuoteAsset(c0, true);
        PoolId id = vault.createBaseLimitPool(key, FeraTypes.Regime.MEME, address(0), SQRT_PRICE_1_1, true, "MEME", "M");

        string memory shareName = IERC20Metadata(vault.shareToken(id, 0)).name();
        assertTrue(_contains(shareName, "TKN"), "reverting symbol() did not fall back to placeholder");
        assertTrue(_contains(shareName, "REAL0"), "the OTHER (well-behaved) token's real symbol should still show");
    }
}
