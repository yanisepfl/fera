// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice TODO-STUBS for invariants that CANNOT be asserted for real yet — either they depend on
///         PROVISIONAL params (frozen only after Pressure-Test V3/V4, MASTER_SPEC §11 gate / DM-6) or
///         on a design decision that is explicitly pending (INV-13). Each test is skipped with
///         `vm.skip(true)` and documents EXACTLY what must land before it can assert.
/// @dev    v3 (contracts/VAULT_STRATEGY_V3.md): the legacy MEME Core/Mid/Tail ladder + drip +
///         INV-5″ guarded-recenter mechanism (and its D-17 band-cap-merge / PT-6 RWA-recenter-
///         interval stubs this file used to carry) is REMOVED — base+limit+idle is now the only
///         strategy, for both regimes. The rebalance-gate-matrix + IL-cap + permissionless-caller
///         coverage that supersedes it is tested for real in
///         `test/integration/BaseLimitStrategy.t.sol` and `test/security/BaseLimitReaudit_PoC.t.sol`
///         (including the base+limit TWAP-sanity leg, which no longer needs a stub — the hook's real
///         cumulative-tick oracle is wired). INV-1″ is tested in `test/hook/JitPenalty.t.sol`; R-17
///         in `test/integration/RatchetPoC.t.sol`.
contract PendingInvariantsTest is Test {
    /// INV-4 — Vault share value never DECREASES from a strategy action (beyond bounded swap/gas).
    /// PARTIAL: `SharePriceCheckpoint` (F-8, `uint8 tranche`) is EMITTED at every checkpoint and the
    /// guarded base recenter enforces both the execution-slippage bound (RebalanceSlippage) and the
    /// v3 IL-budget cap (MAX_IL_BPS_PER_RECENTER). STILL PENDING: a cross-action invariant-handler
    /// campaign asserting monotonicity of sharePriceX96 across randomized deposit/withdraw/skimIdle/
    /// rebalanceLimit/rebalanceBase/selfSwap sequences beyond the bounded arrays already run in
    /// `test/invariant/BaseLimitNavInvariant.t.sol` — a true unbounded StdInvariant handler campaign.
    function test_INV4_sharePriceMonotone_TODO() public {
        vm.skip(true);
    }

    /// INV-13 / PT-2 — CLOSED BY DESIGN (v3.4 staking simplification): the boost concept was
    /// REMOVED (power = flat pro-rata staked FERA; `boostOf` deleted), so the wash-farming vector
    /// (which required a >1x self-boost) no longer exists — "wash-farming net-negative by
    /// arithmetic" (SHARED_CONTEXT) now holds unconditionally. If a fixed loyalty boost is ever
    /// reintroduced, INV-13 (a+b) must be re-satisfied first — see AnchorStaking's closure note.
    function test_INV13_boostWashFarm_CLOSED_byNoBoostDesign() public {
        vm.skip(true); // nothing left to assert on-chain: no boost path exists
    }
}
