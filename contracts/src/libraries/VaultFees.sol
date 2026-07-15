// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFeraShare} from "../interfaces/IFeraShare.sol";
import {IFeraVault} from "../interfaces/IFeraVault.sol";
import {IRevenueDistributor} from "../interfaces/IRevenueDistributor.sol";
import {IAnchorStaking} from "../interfaces/IAnchorStaking.sol";
import {FeraConstants} from "./FeraConstants.sol";
import {VaultOps} from "./VaultOps.sol";
import {VaultMath} from "./VaultMath.sol";
import {TrancheState, PoolInfo} from "./VaultTypes.sol";

/// @title VaultFees
/// @notice EIP-170 SIZE-SPLIT of FeraVault (companion to VaultOps/VaultMath). Holds the fee
///         checkpoint + v3.1 unified fee-routing (§9) + share-price checkpoint bodies as PUBLIC
///         library functions, deployed as SEPARATE bytecode and delegatecalled from FeraVault.
///         Behavior is byte-identical to the pre-split inline code (INV-3 10% skim, the swap/no-swap/
///         fallback routing, the no-staker reroute, and every emitted event are unchanged) — a
///         mechanical relocation to shrink the vault's runtime size. Events are emitted with their
///         canonical `IFeraVault.*` signatures, so on-chain logs are identical.
library VaultFees {
    using SafeERC20 for IERC20;

    // Callback action tags — MUST match FeraVault's internal encoding.
    uint8 internal constant CB_CHECKPOINT = 0;
    uint8 internal constant CB_ROUTE_FEE_SWAP = 9;

    /// @dev Poke the tranche's bands (realizing fees), skim EXACTLY 10%, retain 90% as pending LP
    ///      income (INV-3/INV-15). Then route the perf fee (§9) and emit the fee + share-price events.
    function checkpoint(
        TrancheState storage tr,
        PoolInfo storage p,
        VaultOps.Ctx memory c,
        IRevenueDistributor rd,
        IAnchorStaking anchor
    ) public returns (uint256 fee0, uint256 fee1, uint256 perfFee0, uint256 perfFee1) {
        (fee0, fee1) =
            abi.decode(c.pm.unlock(abi.encode(CB_CHECKPOINT, c.id, c.t, bytes(""))), (uint256, uint256));

        uint256 lpFee0;
        uint256 lpFee1;
        (perfFee0, perfFee1, lpFee0, lpFee1) = _previewPerfFee(fee0, fee1);

        _routeUnifiedPerfFee(p, c, rd, anchor, perfFee0, perfFee1);

        tr.pending0 += lpFee0;
        tr.pending1 += lpFee1;

        emit IFeraVault.FeesCollected(PoolId.unwrap(c.id), fee0, fee1, perfFee0, perfFee1, c.t);
        _emitSharePriceCheckpoint(tr, c);
    }

    /// @dev perfFee = floor(fee * 10%); lpFee = fee - perfFee. Exactly 10% of collected fees.
    function _previewPerfFee(uint256 fee0, uint256 fee1)
        internal
        pure
        returns (uint256 perfFee0, uint256 perfFee1, uint256 lpFee0, uint256 lpFee1)
    {
        perfFee0 = (fee0 * FeraConstants.PERF_FEE_BPS) / FeraConstants.BPS;
        perfFee1 = (fee1 * FeraConstants.PERF_FEE_BPS) / FeraConstants.BPS;
        lpFee0 = fee0 - perfFee0;
        lpFee1 = fee1 - perfFee1;
    }

    /// @dev v3.1 unified fee-routing (§9). Both sides on the reward-token allowlist ⇒ route directly;
    ///      else bound-self-swap the native-side fee into the quote asset (fail-static to in-kind
    ///      treasury on any revert). anchorStaking==0 ⇒ pre-unified behavior (route both directly).
    function _routeUnifiedPerfFee(
        PoolInfo storage p,
        VaultOps.Ctx memory c,
        IRevenueDistributor rd,
        IAnchorStaking anchor,
        uint256 perfFee0,
        uint256 perfFee1
    ) internal {
        if (perfFee0 == 0 && perfFee1 == 0) return;

        if (address(anchor) == address(0)) {
            _routePerfFee(rd, anchor, p.key.currency0, perfFee0);
            _routePerfFee(rd, anchor, p.key.currency1, perfFee1);
            return;
        }

        bool isQuoteToken0 = p.quoteIsToken0;
        Currency quoteCurrency = isQuoteToken0 ? p.key.currency0 : p.key.currency1;
        Currency nativeCurrency = isQuoteToken0 ? p.key.currency1 : p.key.currency0;
        uint256 quotePerfFee = isQuoteToken0 ? perfFee0 : perfFee1;
        uint256 nativePerfFee = isQuoteToken0 ? perfFee1 : perfFee0;

        bool nativeAllowed = anchor.isRewardToken(Currency.unwrap(nativeCurrency));
        bool quoteAllowed = anchor.isRewardToken(Currency.unwrap(quoteCurrency));

        if (nativeAllowed && quoteAllowed) {
            _routePerfFee(rd, anchor, p.key.currency0, perfFee0);
            _routePerfFee(rd, anchor, p.key.currency1, perfFee1);
            return;
        }

        if (nativePerfFee != 0) {
            bool zeroForOne = !isQuoteToken0; // native==token0 (quote==token1) sells token0 for token1
            try c.pm.unlock(abi.encode(CB_ROUTE_FEE_SWAP, c.id, c.t, abi.encode(zeroForOne, nativePerfFee)))
            returns (bytes memory ret) {
                uint256 swappedOut = abi.decode(ret, (uint256));
                quotePerfFee += swappedOut;
                emit IFeraVault.PerfFeeSwapped(
                    PoolId.unwrap(c.id),
                    c.t,
                    Currency.unwrap(nativeCurrency),
                    nativePerfFee,
                    Currency.unwrap(quoteCurrency),
                    swappedOut
                );
            } catch {
                _forwardInKindToTreasury(rd, c, Currency.unwrap(nativeCurrency), nativePerfFee);
            }
        }

        _routePerfFee(rd, anchor, quoteCurrency, quotePerfFee);
    }

    /// @dev Route one currency's perf-fee through RevenueDistributor's 50/25/25 split; zero total
    ///      staked ⇒ fold the stakers' 50% leg into treasury (`notifyRevenueNoStakers`).
    function _routePerfFee(IRevenueDistributor rd, IAnchorStaking anchor, Currency cur, uint256 amount) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(cur);
        IERC20(token).safeTransfer(address(rd), amount);
        if (address(anchor) != address(0) && anchor.totalStaked() == 0) {
            rd.notifyRevenueNoStakers(token, amount);
        } else {
            rd.notifyRevenue(token, amount);
        }
    }

    /// @dev FAIL-STATIC forward: a hostile/reverting/fee-on-transfer native token must NEVER brick
    ///      collectFees. Raw low-level call, tolerates failure either way (dust stays in the vault).
    function _forwardInKindToTreasury(IRevenueDistributor rd, VaultOps.Ctx memory c, address token, uint256 amount)
        internal
    {
        if (amount == 0) return;
        address treasury_ = rd.treasury();
        (bool ok,) = token.call(abi.encodeCall(IERC20.transfer, (treasury_, amount)));
        emit IFeraVault.PerfFeeInKindFallback(PoolId.unwrap(c.id), c.t, token, amount, ok);
    }

    function _emitSharePriceCheckpoint(TrancheState storage tr, VaultOps.Ctx memory c) internal {
        uint256 supply = IFeraShare(tr.share).totalSupply();
        if (supply == 0) return;
        (uint256 v,,) = VaultMath.trancheValue(tr, c);
        // epochId derived from the frozen EPOCH_LENGTH; Backend reconciles against the controller.
        emit IFeraVault.SharePriceCheckpoint(
            PoolId.unwrap(c.id), FullMath.mulDiv(v, 1 << 96, supply), block.timestamp / FeraConstants.EPOCH_LENGTH, c.t
        );
    }
}
