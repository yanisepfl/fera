// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Proof test for the "cooldownExempt withdrawal floor assumes a per-depositor JIT clock"
///         finding (audit finding, medium, v3.5.1): Finding-2's exempt-withdrawal floor NatSpec
///         (`FeraVault.cooldownExempt` mapping doc, `FeraConstants.EXEMPT_WITHDRAW_MARGIN_SEC` doc)
///         claimed "this floor closes that" / "restores that same guarantee", implying the floor
///         protects an exempt address against ANY JIT-forfeiture window. It does not: `FeraHook`'s
///         JIT clock is shared per (pool, tranche, band), not per-depositor, so a different
///         depositor's ordinary deposit or a keeper rebalance can re-arm the same band after the
///         exempt floor has elapsed and still forfeit the exempt address's fees on withdrawal (see
///         `test/security/JitAndVault_PoC.t.sol::test_cooldownExempt_floorDoesNotProtect_againstThirdPartyReArm`
///         for the behavioral proof). This is not a runtime/value change (the floor's arithmetic is
///         unchanged -- see FeraConstants.t.sol for the pre-existing value-pinning pattern this
///         mirrors), so a value-only assertion cannot distinguish the overclaiming NatSpec from the
///         corrected one; this test reads the source files and pins the WORDING instead. Run against
///         the pre-fix files (which asserted the floor "closes" / "restores that same guarantee"
///         with no residual caveat) this test's assertions fail; against the fixed files they pass.
contract CooldownExemptFloorNatSpec_Test is Test {
    string internal constant VAULT_PATH = "src/FeraVault.sol";
    string internal constant CONSTANTS_PATH = "src/libraries/FeraConstants.sol";

    /// FeraVault.sol's `cooldownExempt` mapping NatSpec must no longer claim the floor is a general
    /// guarantee, and must document the shared-clock residual + its THREAT_MODEL.md cross-reference.
    function test_feraVault_cooldownExemptDoc_noLongerOverclaimsGuarantee() public view {
        string memory src = vm.readFile(VAULT_PATH);

        assertTrue(
            _contains(src, "this floor closes THAT self-inflicted"),
            "FeraVault.sol must scope the floor's guarantee to the self-inflicted Finding-2 round trip, "
            "not every JIT-forfeiture window"
        );
        assertTrue(
            _contains(src, "NOT a general guarantee against every JIT-forfeiture window"),
            "must state the floor is not a general guarantee"
        );
        assertTrue(
            _contains(src, 'Vault self-interaction" / V2-3'),
            "FeraVault.sol must cross-reference the V2-3 shared-clock residual"
        );
        assertTrue(
            !_contains(src, "this floor closes that while"),
            "the old, unscoped 'this floor closes that' overclaim must be gone"
        );
    }

    /// FeraConstants.sol's `EXEMPT_WITHDRAW_MARGIN_SEC` NatSpec must carry the same correction: the
    /// "restores that same guarantee" language must be followed by an explicit narrowing to the
    /// self-inflicted case plus the shared-clock residual.
    function test_feraConstants_marginDoc_carriesSharedClockCorrection() public view {
        string memory src = vm.readFile(CONSTANTS_PATH);

        assertTrue(
            _contains(src, "v3.5.1 CORRECTION"),
            "FeraConstants.sol must carry an explicit v3.5.1 correction note on EXEMPT_WITHDRAW_MARGIN_SEC"
        );
        assertTrue(
            _contains(src, "SHARED across every depositor and the keeper, not per-depositor"),
            "must document the JIT clock is shared per (pool,tranche,band), not per-depositor"
        );
        assertTrue(
            _contains(src, "MEME_MIN_REBALANCE_INTERVAL_SEC exactly equals JIT_PENALTY_WINDOW_MEME"),
            "must document the MEME rebalance-cadence / JIT-window coincidence"
        );
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return n.length == 0;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
