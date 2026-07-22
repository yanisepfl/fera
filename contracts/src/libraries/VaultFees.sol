// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
/// @dev    AUDIT NOTE (Informational, v3.5): these `public` functions are DELEGATECALL-ONLY by
///         design (invoked only via FeraVault's linked reference) — see VaultOps.sol's identical
///         note (and test/unit/LibraryDirectCall_PoC.t.sol) for the empirically-verified detail:
///         for this storage-struct-parameter signature shape, the library's OWN dispatcher does not
///         even recognize the function's documented selector via a plain external `CALL`.
library VaultFees {
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
            _routePerfFee(rd, anchor, c, p.key.currency0, perfFee0);
            _routePerfFee(rd, anchor, c, p.key.currency1, perfFee1);
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
            _routePerfFee(rd, anchor, c, p.key.currency0, perfFee0);
            _routePerfFee(rd, anchor, c, p.key.currency1, perfFee1);
            return;
        }

        if (nativePerfFee != 0) {
            bool zeroForOne = !isQuoteToken0; // native==token0 (quote==token1) sells token0 for token1
            // Audit finding (Medium, open-kritt / OPEN_DECISIONS.md#OD-17): the self-swap's minOut is
            // TWAP-anchored, but `consultTwapTick`'s `ready` flag only requires >0 seconds of elapsed
            // time — a pool whose oracle ring holds no checkpoint older than this window (e.g. shortly
            // after its first-ever swap, before TWAP_OBS_SPACING_SEC has let one freeze) can have its
            // "TWAP" collapse to whatever tick the attacker's OWN immediately-preceding swap just set,
            // making the 1% bound a no-op against a reference the attacker just shaped. OD-17's own
            // verdict was already BOUNDED (the dyn-fee/slippage interaction still caps the loss to
            // that pool's own perf fee), but this closes the gap for real per OD-17's recommended
            // hardening: require genuine window-spanning history before trusting the self-swap's
            // TWAP bound at all; otherwise skip straight to the fail-static in-kind fallback (routing
            // efficiency cost only — never blocks fee collection, never risks depositor principal).
            (uint32 oldestAge, bool hasHistory) = c.hook.oldestObservationAge(c.id);
            if (hasHistory && oldestAge >= FeraConstants.REBALANCE_TWAP_WINDOW_SEC) {
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
            } else {
                _forwardInKindToTreasury(rd, c, Currency.unwrap(nativeCurrency), nativePerfFee);
            }
        }

        _routePerfFee(rd, anchor, c, quoteCurrency, quotePerfFee);
    }

    /// @dev Route one currency's perf-fee through RevenueDistributor's 50/25/25 split; zero total
    ///      staked ⇒ fold the stakers' 50% leg into treasury (`notifyRevenueNoStakers`).
    /// @dev Audit finding (Medium, open-kritt): the transfer used to be a bare `safeTransfer` with no
    ///      failure containment, unlike the sibling swap branch above (which already `try/catch`es
    ///      and falls back to `_forwardInKindToTreasury`). `createBaseLimitPool` only allowlists the
    ///      QUOTE-side currency — the NATIVE side is fully attacker-chosen — so a pool created with a
    ///      hostile/reverting native token reached this DIRECT (no-swap) route whenever anchor staking
    ///      was unset or both sides happened to be reward-allowed, and a reverting `safeTransfer`
    ///      propagated all the way up through `checkpoint`/`collectFees`, permanently bricking fee
    ///      collection for that pool — violating this library's own stated invariant that a hostile
    ///      token must NEVER brick `collectFees`. Fixed: a raw low-level call (never reverts) plus a
    ///      `try/catch` around the RevenueDistributor notify (covers a token that reports success
    ///      without truly delivering the balance, which trips RevenueDistributor's own delta guard);
    ///      either failure falls back to the same fail-static in-kind forward the swap branch uses.
    function _routePerfFee(IRevenueDistributor rd, IAnchorStaking anchor, VaultOps.Ctx memory c, Currency cur, uint256 amount)
        internal
    {
        if (amount == 0) return;
        address token = Currency.unwrap(cur);
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (address(rd), amount)));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) {
            if (address(anchor) != address(0) && anchor.totalStaked() == 0) {
                try rd.notifyRevenueNoStakers(token, amount) {
                    return;
                } catch { }
            } else {
                try rd.notifyRevenue(token, amount) {
                    return;
                } catch { }
            }
        }
        _forwardInKindToTreasury(rd, c, token, amount);
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
