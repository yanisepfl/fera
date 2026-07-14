// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEsFera} from "../../src/interfaces/IEsFera.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";
import {IRebalanceVenue} from "../../src/interfaces/IRebalanceVenue.sol";

/// @title Test mocks for the FERA suite.
/// @notice Kept in one file so unit tests share a consistent, minimal set of "weird ERC-20"
///         and interface stubs used to probe the money-path policy (SafeERC20, CEI, INV-8).

/// @dev A standard, well-behaved 18-decimal ERC-20 with an open mint (test funding).
contract MintableERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev "Missing/false return" weird token: transfer/transferFrom return `false` WITHOUT reverting
///      and WITHOUT moving funds. Any money path that does not use SafeERC20 would silently treat
///      this as success — SafeERC20 MUST revert on it. (Weird-ERC20 matrix, THREAT_MODEL.)
contract ReturnsFalseERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint8 public constant decimals = 18;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    // Deliberately returns false and does nothing.
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev Callback-on-transfer token (ERC-777-style hazard): after moving funds it re-enters a
///      registered target, letting tests prove CEI on the money paths (no double-withdraw).
interface IReentrancyVictim {
    function onTokenReceived() external;
}

contract CallbackERC20 is ERC20 {
    address public callbackTarget;
    bool public reenterOn;

    constructor() ERC20("CB", "CB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setCallback(address target, bool on) external {
        callbackTarget = target;
        reenterOn = on;
    }

    function transfer(address to, uint256 amount) public override returns (bool ok) {
        ok = super.transfer(to, amount);
        if (reenterOn && to == callbackTarget && to.code.length != 0) {
            IReentrancyVictim(to).onTokenReceived();
        }
    }
}

/// @dev Attacker that tries to re-enter RevenueDistributor.pull via CallbackERC20's transfer hook.
contract PullReenterer is IReentrancyVictim {
    IRevenueDistributor public immutable dist;
    address public immutable token;

    constructor(IRevenueDistributor dist_, address token_) {
        dist = dist_;
        token = token_;
    }

    function attack() external {
        dist.pull(token);
    }

    function onTokenReceived() external override {
        // Re-entrant second pull; pending is already zeroed (CEI) so this MUST revert NothingToPull.
        dist.pull(token);
    }
}

/// @dev Minimal IEsFera stand-in so Distributor (INV-8) can be tested without the FERA↔EsFera↔
///      Distributor immutable cycle. Records mints; the double-claim logic under test is entirely
///      in Distributor's bitmap, independent of EsFera.
contract MockEsFera is IEsFera {
    event Minted(address indexed account, uint256 amount);

    uint256 public totalMinted;

    function mintAndVest(address account, uint256 amount) external override {
        totalMinted += amount;
        emit Minted(account, amount);
    }

    function claimVested() external pure override returns (uint256) {
        return 0;
    }

    function instantExit(uint256) external pure override returns (uint256) {
        return 0;
    }

    function claimable(address) external pure override returns (uint256) {
        return 0;
    }
}

/// @dev Minimal EmissionsController stand-in so Distributor (R-19 envelope) can be tested without
///      the FERA↔EsFera↔Distributor↔EmissionsController immutable cycle. Records per-epoch funded
///      amounts + finalized flags; the postRoot/claim envelope logic under test is in Distributor.
contract MockEmissionsController {
    mapping(uint256 => uint256) public emittedOf;
    mapping(uint256 => bool) public finalized;

    function setEmitted(uint256 epochId, uint256 amount) external {
        emittedOf[epochId] = amount;
        finalized[epochId] = true;
    }
}

/// @dev Chainlink AggregatorV3 mock with settable answer/staleness and per-feed decimals (D-9).
contract MockAggregatorV3 is IAggregatorV3 {
    uint8 public immutable decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}

/// @dev Whitelisted external rebalance-venue stand-in (IRebalanceVenue). Swaps `tokenIn`→`tokenOut`
///      at a configurable `rateBps` (10_000 = 1:1) and delivers to the recipient. Deliberately does
///      NOT enforce `minOut` itself so tests can exercise the VAULT's own on-chain TWAP-slippage
///      post-check (RebalanceSlippage). `reverting` models a down/hostile venue — the Vault's bounded
///      call must isolate it (whole tx reverts) while the in-kind `withdraw` fallback stays available.
///      Must be pre-funded with `tokenOut`.
contract MockRebalanceVenue is IRebalanceVenue {
    uint256 public rateBps = 10_000;
    bool public reverting;

    function setRate(uint256 r) external {
        rateBps = r;
    }

    function setReverting(bool r) external {
        reverting = r;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256, address recipient)
        external
        returns (uint256 amountOut)
    {
        if (reverting) revert("venue down");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * rateBps) / 10_000;
        IERC20(tokenOut).transfer(recipient, amountOut);
    }
}

/// @dev HOSTILE venue that RE-ENTERS the Vault during `swapExactIn` (models reentrancy via the
///      untrusted external-call surface / a malicious `tokenIn` transfer callback). It captures the
///      reentry result and still completes an honest swap, so a test can assert the reentry was
///      BLOCKED by the Vault's global `nonReentrant` while the bounded call itself proceeds.
contract ReentrantRebalanceVenue is IRebalanceVenue {
    uint256 public rateBps = 10_000;
    address public reenterTarget;
    bytes public reenterData;
    bool public reentryAttempted;
    bool public reentryReverted;

    function arm(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function setRate(uint256 r) external {
        rateBps = r;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256, address recipient)
        external
        returns (uint256 amountOut)
    {
        if (reenterTarget != address(0)) {
            reentryAttempted = true;
            // Low-level call so the reentry's revert does NOT bubble — we record whether the Vault's
            // guard rejected it, then complete the honest swap.
            (bool ok,) = reenterTarget.call(reenterData);
            reentryReverted = !ok;
        }
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * rateBps) / 10_000;
        IERC20(tokenOut).transfer(recipient, amountOut);
    }
}

/// @dev RETURN-DATA-BOMB venue: `swapExactIn` declares a `uint256` return but returns an enormous ABI
///      blob. The Vault ignores the return value (it measures output by `balanceOf` delta), so a
///      well-behaved caller must NOT OOG / DoS on the oversized returndata (Solidity 0.8 does not copy
///      an unused static return). Delivers `tokenOut` honestly so the bounded call otherwise succeeds.
contract ReturnBombRebalanceVenue is IRebalanceVenue {
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256, address recipient)
        external
        returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(recipient, amountIn); // 1:1 fair delivery
        assembly {
            // Return 128 KB of zeros regardless of the declared uint256 return type.
            return(mload(0x40), 131072)
        }
    }
}

/// @dev LYING venue: claims an enormous `amountOut` via the RETURN VALUE but delivers only a sliver of
///      `tokenOut`. The Vault must IGNORE the return and catch the shortfall via `balanceOf` delta
///      (< minOut) → revert `RebalanceSlippage`. Equivalent, from the Vault's measurement standpoint,
///      to a fee-on-transfer `tokenOut` that skims the delivery.
contract LyingRebalanceVenue is IRebalanceVenue {
    uint256 public deliverBps = 1; // deliver 0.01% of amountIn as tokenOut (a lie vs the claimed return)

    function setDeliverBps(uint256 b) external {
        deliverBps = b;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256, address recipient)
        external
        returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 delivered = (amountIn * deliverBps) / 10_000;
        if (delivered != 0) IERC20(tokenOut).transfer(recipient, delivered);
        return type(uint256).max; // the lie: claim to have delivered the maximum
    }
}

/// @dev Chainlink feed that REVERTS on latestRoundData() — proves the hook's oracle-fail try/catch
///      (INV-2: a swap NEVER reverts because the price feed is broken; the fee falls back to blind).
contract RevertingAggregatorV3 is IAggregatorV3 {
    uint8 public constant decimals = 8;

    function latestRoundData() external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert("feed down");
    }
}

/// @dev Hostile "native/project token" for the v3.1 unified fee-routing tests
///      (contracts/VAULT_STRATEGY_V3.md §9). Two independently-configurable hostile shapes on the
///      SAME token, so the fee-routing fail-static path can be probed against both:
///       - `setBlockedSender`: `transfer` REVERTS whenever the CALLER (msg.sender) is the blocked
///         address — models a token that rejects THIS PARTICULAR CONTRACT's own outgoing transfers
///         (e.g. an anti-bot memecoin, or a compromised/blacklisting token) while transfers from
///         OTHER senders (e.g. the PoolManager's routine fee payout via `.take()`) are unaffected.
///       - `setFeeBps`: a fee-on-transfer deduction (bps burned on every transfer) — the sender pays
///         the full `amount` but the recipient receives less; models a deflationary/tax token.
contract HostileNativeERC20 is ERC20 {
    address public blockedSender;
    uint256 public feeBps; // burned on every transfer, 0 = none (bps of 10_000)

    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlockedSender(address who) external {
        blockedSender = who;
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blockedSender != address(0) && msg.sender == blockedSender) revert("hostile: sender blocked");
        if (feeBps != 0 && amount != 0) {
            uint256 fee = (amount * feeBps) / 10_000;
            if (fee != 0) _burn(msg.sender, fee);
            return super.transfer(to, amount - fee);
        }
        return super.transfer(to, amount);
    }
}
