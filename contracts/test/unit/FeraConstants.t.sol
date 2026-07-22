// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeraConstants} from "../../src/libraries/FeraConstants.sol";

/// @notice Proof test for the "MEME_FLOW_LAMBDA_RELEASE / MEME_VOL_LAMBDA_DOWN coincidental literal"
///         finding: the two constants were independently-declared `uint256 internal constant`
///         literals that happened to both equal 64_225 (0.98·2^16), with no compiler-enforced link
///         and no comment stating whether the equality was deliberate. A future maintainer retuning
///         MEME_VOL_LAMBDA_DOWN would get no signal that MEME_FLOW_LAMBDA_RELEASE was a sibling that
///         did not move with it, or a maintainer "deduplicating" the two literals could silently
///         change one of two genuinely-different estimators (squared-return magnitude vs. signed
///         order flow) that the v3.5 fix intentionally decoupled.
/// @dev    The fix (contracts/src/libraries/FeraConstants.sol) makes MEME_FLOW_LAMBDA_RELEASE a
///         direct source-level reference to MEME_VOL_LAMBDA_DOWN (`= MEME_VOL_LAMBDA_DOWN`) instead
///         of its own literal, plus NatSpec on both constants stating the equality is intentional.
///         This is behavior-preserving by construction (both still evaluate to 64_225), so a
///         value-only assertion cannot distinguish "independent literals that happen to match" from
///         "compiler-enforced link" — both states pass it identically. The property actually being
///         fixed is a SOURCE-level one (a real derivation exists, not a coincidental duplicate), so
///         this test additionally reads the source file and asserts the derivation text is present.
///         Run against the pre-fix file (two independent `= 64_225` literals, no cross-reference)
///         this test's second assertion fails; against the fixed file it passes.
contract FeraConstants_LambdaLink_Test is Test {
    string internal constant CONSTANTS_PATH = "src/libraries/FeraConstants.sol";

    /// Runtime sanity: the shared slow-release design value is unchanged by the fix (still
    /// 0.98·2^16), and remains distinct from the deliberately-decoupled attack-side pair
    /// (MEME_VOL_LAMBDA_UP vs. MEME_FLOW_LAMBDA_ATTACK are NOT linked — only DOWN/RELEASE are).
    function test_flowLambdaRelease_valueMatches_volLambdaDown() public pure {
        assertEq(
            FeraConstants.MEME_FLOW_LAMBDA_RELEASE,
            FeraConstants.MEME_VOL_LAMBDA_DOWN,
            "flow-release and vol-down must share the same slow-release rate"
        );
        assertEq(FeraConstants.MEME_FLOW_LAMBDA_RELEASE, 64_225, "shared slow-release literal moved unexpectedly");
        assertTrue(
            FeraConstants.MEME_VOL_LAMBDA_UP != FeraConstants.MEME_FLOW_LAMBDA_ATTACK,
            "attack-side pair is deliberately NOT linked -- only DOWN/RELEASE should be"
        );
    }

    /// Source-level proof that the equality above is a compiler-enforced DERIVATION, not two
    /// independent literals that happen to collide. This is the actual finding: nothing previously
    /// stopped MEME_VOL_LAMBDA_DOWN from being retuned without anyone reviewing whether
    /// MEME_FLOW_LAMBDA_RELEASE should move too.
    function test_flowLambdaRelease_isSourceDerivedFrom_volLambdaDown() public {
        string memory src = vm.readFile(CONSTANTS_PATH);

        assertTrue(
            _contains(src, "MEME_FLOW_LAMBDA_RELEASE = MEME_VOL_LAMBDA_DOWN"),
            "MEME_FLOW_LAMBDA_RELEASE must be declared as `= MEME_VOL_LAMBDA_DOWN`, "
            "not an independently-chosen literal -- see FeraConstants.sol NatSpec"
        );
        // The attack-side pair must NOT be similarly linked -- they are genuinely different
        // per-signal tunings (v3.5 fix deliberately kept flow's attack side off vol's fast constant).
        assertTrue(
            !_contains(src, "MEME_FLOW_LAMBDA_ATTACK = MEME_VOL_LAMBDA_UP"),
            "MEME_FLOW_LAMBDA_ATTACK must stay an independent literal, not linked to MEME_VOL_LAMBDA_UP"
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
