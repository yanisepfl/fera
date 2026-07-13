// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEsFera} from "../../src/interfaces/IEsFera.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IRevenueDistributor} from "../../src/interfaces/IRevenueDistributor.sol";

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

/// @dev Chainlink feed that REVERTS on latestRoundData() — proves the hook's oracle-fail try/catch
///      (INV-2: a swap NEVER reverts because the price feed is broken; the fee falls back to blind).
contract RevertingAggregatorV3 is IAggregatorV3 {
    uint8 public constant decimals = 8;

    function latestRoundData() external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert("feed down");
    }
}
