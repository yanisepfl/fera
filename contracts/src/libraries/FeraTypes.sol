// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title FeraTypes
/// @notice Shared enums/structs used across the FERA contract set. Kept in one place so the
///         Hook, Vault, and interfaces cannot drift on the encoding of Regime / StrategyKind.
/// @dev    MASTER_SPEC §5: `enum Regime { MEME, RWA }` — EVENT is reserved for v2 and MUST NOT
///         be appended to the enum until then (would shift the on-chain uint8 encoding).
library FeraTypes {
    /// @notice Fee-pricing policy bound to a pool at initialization. Immutable post-init.
    /// MEME = 0, RWA = 1. Do NOT add EVENT here before v2 (breaks the `uint8 regime` ABI).
    enum Regime {
        MEME, // 0
        RWA // 1
    }

    /// @notice Share class on the Vault. LP is the live v1 class; LAUNCHPAD is present in the
    ///         type system but gated off in v1 (non-redeemable, auto-compounding). D-1 / §4.
    enum ShareClass {
        LP, // 0 — redeemable fungible ERC-20 vault share
        LAUNCHPAD // 1 — non-redeemable, locked, auto-compounding (v1: gated OFF)
    }

    /// @notice StrategyAction.kind encoding — MUST match MASTER_SPEC §6 StrategyAction comment
    ///         (+ the F-8 batch: kind=5 dripDeploy; + F-9: kind=6 bandConsolidate).
    /// 0=initialMint 1=recenter 2=widen(RWA off-hours) 3=partialWithdraw(RWA) 4=compoundInPlace
    /// 5=dripDeploy (fee-income into a NEW band) 6=bandConsolidate (D-17 fee-band merge).
    enum StrategyKind {
        InitialMint, // 0
        Recenter, // 1 — RWA oracle-anchored recenter AND the guarded MEME recenter (INV-5″)
        Widen, // 2
        PartialWithdraw, // 3
        CompoundInPlace, // 4 — keeper `compound()` fee income into a tranche's PRIMARY band
        DripDeploy, // 5 — fee income into a NEW single-sided no-swap band (F-8 / D-15)
        BandConsolidate // 6 — drip merged into an EXISTING fee band (F-9 / D-17; was mis-tagged 4)
    }

    /// @notice Risk tranche index on a pool (D-12/D-16). MEME pools ship Core only; RWA pools ship
    ///         Core + Anchor over DISJOINT band sets (INV-15). uint8 in events (F-8).
    enum TrancheId {
        Core, // 0 — concentrated bands: higher fee capture, higher IL
        Anchor // 1 — wide/tail bands: lower fee capture, lower IL (RWA only in v1)
    }

    /// @notice Claim kind on the Distributor / emissions leaves. MASTER_SPEC §6/§9.
    /// 0=traderRebate 1=lpReward.
    enum ClaimKind {
        TraderRebate, // 0
        LpReward // 1
    }
}
