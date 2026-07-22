// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultMath} from "../../src/libraries/VaultMath.sol";
import {FeraTypes} from "../../src/libraries/FeraTypes.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

/// @notice Proof test for the "cooldownExempt withdrawal-floor logic is duplicated (not shared)
///         between FeraVault.withdraw() and VaultActions.withdrawSingle()" finding (Low): both paths
///         independently hand-reimplemented `regime-JIT-window + EXEMPT_WITHDRAW_MARGIN_SEC` against
///         the same FeraConstants, consistent today only by manual synchronization. A future retune
///         of either the JIT windows or the margin constant applied to only ONE copy would silently
///         reopen Finding-2's exact vulnerability class (an exempt address donating its own fees via
///         a deposit-then-instant-withdraw) in whichever path was missed.
/// @dev    The fix factors the computation into ONE shared helper, `VaultMath.exemptWithdrawFloorSec`,
///         called directly by both `FeraVault._exemptWithdrawFloorSec` (-> `withdraw`) and
///         `VaultActions.withdrawSingle`. This is behavior-preserving by construction (both paths
///         still compute the exact same numbers as before), so a value-only assertion cannot
///         distinguish "one shared helper" from "two independent copies that happen to match" --
///         both states pass it identically. The property actually being fixed is a SOURCE-level one
///         (a real single implementation exists, not a hand-synced duplicate), so this test
///         additionally reads FeraVault.sol / VaultActions.sol and asserts each calls the shared
///         helper instead of inlining the regime/JIT-window lookup itself. Run against the pre-fix
///         files (each with its own independent ternary/if-else against FeraConstants) the
///         source-derivation assertions below fail; against the fixed files they pass.
contract VaultMath_ExemptWithdrawFloorDedup_Test is Test {
    string internal constant VAULT_PATH = "src/FeraVault.sol";
    string internal constant ACTIONS_PATH = "src/libraries/VaultActions.sol";

    // ── runtime sanity: the shared helper reproduces the exact pre-fix formula ───────────────
    function test_exemptWithdrawFloorSec_matchesFormula_bothRegimes() public pure {
        uint32 memeFloor = VaultMath.exemptWithdrawFloorSec(FeraTypes.Regime.MEME);
        uint32 rwaFloor = VaultMath.exemptWithdrawFloorSec(FeraTypes.Regime.RWA);

        assertEq(
            memeFloor,
            FeraConstants.JIT_PENALTY_WINDOW_MEME + FeraConstants.EXEMPT_WITHDRAW_MARGIN_SEC,
            "MEME floor must equal its JIT window + margin"
        );
        assertEq(
            rwaFloor,
            FeraConstants.JIT_PENALTY_WINDOW_RWA + FeraConstants.EXEMPT_WITHDRAW_MARGIN_SEC,
            "RWA floor must equal its JIT window + margin"
        );
        // Sanity pin so a silent constant retune doesn't drift this test's own expectations away
        // from the values the finding was verified against (JIT 1800/600, margin 600).
        assertEq(memeFloor, 2_400, "MEME floor moved unexpectedly");
        assertEq(rwaFloor, 1_200, "RWA floor moved unexpectedly");
        assertLt(memeFloor, FeraConstants.DEPOSIT_COOLDOWN_SEC, "exempt floor must stay under the full cooldown");
        assertLt(rwaFloor, FeraConstants.DEPOSIT_COOLDOWN_SEC, "exempt floor must stay under the full cooldown");
    }

    // ── source-level proof: FeraVault.withdraw's helper delegates, it does not reimplement ──────
    function test_feraVault_exemptWithdrawFloor_delegatesToSharedHelper() public {
        string memory src = vm.readFile(VAULT_PATH);

        assertTrue(
            _contains(src, "return VaultMath.exemptWithdrawFloorSec(pools[id].regime);"),
            "FeraVault._exemptWithdrawFloorSec must delegate to the shared VaultMath helper, "
            "not reimplement the regime/JIT-window lookup inline"
        );
        // The pre-fix duplicate computed its own jitWindow from the raw constants right here --
        // that inline reimplementation must be gone now that it delegates.
        assertTrue(
            !_contains(
                src,
                "uint32 jitWindow = pools[id].regime == FeraTypes.Regime.MEME\n"
                "            ? FeraConstants.JIT_PENALTY_WINDOW_MEME\n"
                "            : FeraConstants.JIT_PENALTY_WINDOW_RWA;"
            ),
            "FeraVault must no longer hand-reimplement the jitWindow ternary -- that is the exact "
            "duplication the finding flagged"
        );
    }

    // ── source-level proof: VaultActions.withdrawSingle calls the SAME shared helper ───────────
    function test_vaultActions_withdrawSingle_delegatesToSharedHelper() public {
        string memory src = vm.readFile(ACTIONS_PATH);

        assertTrue(
            _contains(src, "VaultMath.exemptWithdrawFloorSec(p.regime)"),
            "VaultActions.withdrawSingle must call the SAME shared VaultMath helper FeraVault uses, "
            "not its own independent computation"
        );
        // Pre-fix, withdrawSingle inlined its own copy of the regime/JIT-window lookup directly
        // against FeraConstants -- those raw constant names must no longer appear in this file at
        // all once the only reference to them is inside VaultMath's shared helper.
        assertTrue(
            !_contains(src, "JIT_PENALTY_WINDOW_MEME") && !_contains(src, "JIT_PENALTY_WINDOW_RWA"),
            "VaultActions must no longer reference the JIT window constants directly -- that hand-"
            "duplicated computation is exactly what the finding flagged as able to silently drift "
            "from FeraVault.withdraw's copy"
        );
        assertTrue(
            !_contains(src, "EXEMPT_WITHDRAW_MARGIN_SEC"),
            "VaultActions must no longer reference EXEMPT_WITHDRAW_MARGIN_SEC directly -- it must "
            "come only from the shared VaultMath helper"
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
