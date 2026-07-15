// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IFeraShare} from "../interfaces/IFeraShare.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Minimal read-only view into the owning Vault for ERC-4626-style share pricing. PoolId is a
///      `type PoolId is bytes32`, so these bytes32 selectors match the vault's PoolId-typed views.
interface IVaultShareOracle {
    function quoteNav(bytes32 id, uint8 tranche) external view returns (uint256);
    function quoteAsset(bytes32 id) external view returns (address);
}

/// @title FeraShare
/// @notice Per-pool ERC-20 vault share (D-1 / MASTER_SPEC §4). Deployed ONCE as an implementation
///         and cloned (EIP-1167 minimal proxy) per pool by the Vault. Mint/burn are Vault-only so
///         a share is a normal, wallet-composable token representing a pro-rata claim on a pool.
/// @dev    Metadata is set in `initialize` (not constructor) because clones share the impl's code
///         and run no constructor. The implementation instance itself is inert (vault == 0).
///         Standard 18-decimal ERC-20. EIP-2612 `permit` is intentionally deferred:
///         TODO(scaffold): add ERC20Permit for gasless approvals (retail composability).
contract FeraShare is IFeraShare {
    // ── ERC-20 metadata (initializable for clones) ────────────────────────────────────────
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    // ── ERC-20 state ──────────────────────────────────────────────────────────────────────
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ── FERA share state ──────────────────────────────────────────────────────────────────
    address public vault;
    bytes32 public poolId;
    uint8 public tranche; // which risk tranche of the pool this share represents (for NAV lookups)

    /// @dev V2-2 (SEC-3 #4): per-account outgoing-transfer lock. The Vault sets this to
    ///      block.timestamp + DEPOSIT_COOLDOWN_SEC on every deposit, so freshly-minted shares can
    ///      NOT be transferred to a second wallet to evade the withdraw cooldown. Redemption
    ///      (burn) is never blocked (INV-11). Mint (from == address(0)) is exempt.
    mapping(address => uint64) public transferLockUntil;

    // NOTE: Transfer/Approval events are inherited from IERC20 (via IFeraShare). Re-declaring them
    // here is a compile error ("Event with same name and parameter types defined twice"), so they
    // are intentionally NOT redeclared — `emit Transfer(...)`/`emit Approval(...)` resolve to IERC20.

    /// @dev Zero-address guard on the clone's one-shot vault wiring (the Vault passes itself).
    error ZeroAddress();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @inheritdoc IFeraShare
    function initialize(
        address vault_,
        bytes32 poolId_,
        uint8 tranche_,
        string calldata name_,
        string calldata symbol_
    ) external {
        if (vault != address(0)) revert AlreadyInitialized();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        poolId = poolId_;
        tranche = tranche_;
        name = name_;
        symbol = symbol_;
    }

    // ── ERC-4626-style pricing (READ-ONLY; for DefiLlama / Rabby) ────────────────────────────────
    // Quote-denominated pricing surface, not a full single-asset ERC-4626 vault: the underlying
    // position holds TWO tokens, so deposits/withdrawals live on the Vault (two-token, slippage-
    // guarded). asset()/convertToAssets()/pricePerShare() give integrators a clean, manipulation-
    // resistant (TWAP) value-per-share in the pool's quote token.

    /// @inheritdoc IFeraShare
    function asset() external view returns (address) {
        return IVaultShareOracle(vault).quoteAsset(poolId);
    }

    /// @inheritdoc IFeraShare
    function totalAssets() public view returns (uint256) {
        return IVaultShareOracle(vault).quoteNav(poolId, tranche);
    }

    /// @inheritdoc IFeraShare
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 ts = totalSupply;
        return ts == 0 ? shares : Math.mulDiv(shares, totalAssets(), ts);
    }

    /// @inheritdoc IFeraShare
    function convertToShares(uint256 assets) external view returns (uint256) {
        uint256 ta = totalAssets();
        return ta == 0 ? assets : Math.mulDiv(assets, totalSupply, ta);
    }

    /// @inheritdoc IFeraShare
    function pricePerShare() external view returns (uint256) {
        return convertToAssets(1e18);
    }

    /// @inheritdoc IFeraShare
    function mint(address to, uint256 amount) external onlyVault {
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    /// @inheritdoc IFeraShare
    function burn(address from, uint256 amount) external onlyVault {
        balanceOf[from] -= amount;
        unchecked {
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    /// @inheritdoc IFeraShare
    function setTransferLock(address account, uint64 until) external onlyVault {
        if (until > transferLockUntil[account]) transferLockUntil[account] = until; // extend-only
    }

    // ── ERC-20 ────────────────────────────────────────────────────────────────────────────
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        // V2-2: block outgoing transfers while the sender's deposit cooldown is active. Mint/burn
        // go through mint()/burn() (not _transfer), so redemption is never affected (INV-11).
        if (block.timestamp < transferLockUntil[from]) revert TransferLocked();
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
