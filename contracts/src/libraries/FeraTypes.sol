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

    /// @notice StrategyAction.kind encoding — MUST match MASTER_SPEC §6 StrategyAction comment.
    ///         v3 (contracts/VAULT_STRATEGY_V3.md): the legacy ladder mechanism was removed, so kinds
    ///         4=CompoundInPlace, 5=DripDeploy, 6=BandConsolidate are NO LONGER EMITTED (their code
    ///         paths are deleted, not stubbed). Values are kept (not renumbered) so historical event
    ///         decoding never shifts.
    ///         V3-HARDENING (2026-07-14, §5.1): kinds 1=Recenter and 2=Widen are RE-EMITTED for the
    ///         RESTORED RWA regime — 1 by the in-hours oracle-anchored base recenter
    ///         (`rebalanceRwaOracle`), 2 by the off-hours/event WIDEN + partial-withdraw defense
    ///         (`defendRwaOffHours`). Their semantics are the base+limit-native heirs of the removed
    ///         ladder-era RWA recenter/widen (same intent, new mechanism — re-anchor the base band,
    ///         not a ladder). 3=PartialWithdraw stays unused (the partial-withdraw is folded into the
    ///         Widen defend, emitted as 2).
    /// 0=initialMint 1=rwaOracleRecenter 2=rwaOffHoursWiden 7=limitDeploy 8=baseRecenter(full)
    /// 9=selfSwap 10=venueSwap 11=skimIdle 12=baseRecenterPartial (v3: IL-budget-capped staged recenter).
    enum StrategyKind {
        InitialMint, // 0
        Recenter, // 1 — RESTORED (v3-hardening): RWA in-hours oracle-anchored base recenter
        Widen, // 2 — RESTORED (v3-hardening): RWA off-hours/event WIDEN + partial-withdraw defense
        PartialWithdraw, // 3 — unused (partial-withdraw folded into the Widen defend, kind 2)
        CompoundInPlace, // 4 — LEGACY, no longer emitted
        DripDeploy, // 5 — LEGACY, no longer emitted
        BandConsolidate, // 6 — LEGACY, no longer emitted
        // base+limit+idle strategy (contracts/VAULT_STRATEGY_V3.md) — THE canonical/only strategy:
        LimitDeploy, // 7 — collect the filled LIMIT + redeploy an inventory-skewed limit (§3)
        BaseRecenter, // 8 — guarded wide-BASE recenter, FULLY executed (dwell + TWAP + slippage + IL-cap)
        SelfSwap, // 9 — bounded ratio-balancing swap against the vault's OWN v4 pool
        VenueSwap, // 10 — bounded ratio-balancing swap through a whitelisted EXTERNAL venue
        SkimIdle, // 11 — pull the configured IDLE fraction of the base into reserve
        BaseRecenterPartial // 12 — v3 NEW: guarded recenter whose self-swap was IL-budget-capped
            // (partial execution; the leftover imbalance is completed by a later action, §4)
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
