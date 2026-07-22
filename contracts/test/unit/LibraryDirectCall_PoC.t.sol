// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultMath} from "../../src/libraries/VaultMath.sol";

/// @notice PoC for the audit's Informational "EIP-170 split libraries expose public functions
///         callable directly, bypassing every FeraVault access-control modifier" finding.
/// @dev    VaultOps/VaultActions/VaultMath/VaultFees/VaultRwa declare their state-changing bodies
///         `public` (not `internal`) so FeraVault can `DELEGATECALL` them from a separate deployed
///         bytecode (the EIP-170 size-split). The finding's premise was that nothing stops a direct
///         (non-delegatecall) `CALL` to e.g. `VaultMath.absorbDepositOverage(...)` at the library's
///         own deployed address, skipping every FeraVault modifier.
///
///         This PoC empirically checks that premise against the ACTUAL compiled bytecode rather
///         than assuming it. Result: for a `public` library function taking a `storage`-struct
///         reference parameter (`TrancheState storage`, `PoolInfo storage`, etc. — the shape used
///         by every state-changing function across all five split libraries), the library's own
///         deployed dispatcher does NOT recognize the function's own documented selector
///         (`forge inspect VaultMath methods` reports `absorbDepositOverage(TrancheState
///         storage,uint256,uint256)` as `0x69072a9b`) when called via a plain external `CALL` —
///         it reverts with "unrecognized function selector ... which has no fallback function"
///         BEFORE any argument decoding or storage access happens. Solidity's codegen for a
///         `storage`-reference parameter in a `public` library function only wires up the
///         DELEGATECALL-style entry point actually used by callers that are compiled against the
///         library (FeraVault, via its linked reference) — the same selector is not a live case in
///         the library's own standalone external dispatch table. So this specific attack surface is
///         narrower than "inert but callable": for every function sharing this signature shape, it
///         is NOT externally callable via ordinary calldata at all. Documented here (rather than
///         asserted from first principles) precisely because it does not match the naive
///         expectation, and a future maintainer should not have to re-derive it.
contract LibraryDirectCall_PoC is Test {
    function test_directCallWithStorageStructParam_rejectedByLibrarysOwnDispatcher() public {
        // A FRESH, standalone deployment of the library's own bytecode — exactly what an attacker
        // would target (the library's real deployed address, reachable identically whether FeraVault
        // ever delegatecalls it or not).
        address lib = deployCode("VaultMath.sol:VaultMath");

        // `absorbDepositOverage(TrancheState storage,uint256,uint256)` — selector confirmed via
        // `forge inspect VaultMath methods`: 0x69072a9b. Used as the representative case: simplest
        // signature (one storage-struct ref + two uint256) sharing the same parameter shape as every
        // other state-changing public function across all five EIP-170 split libraries.
        bytes memory callData = abi.encodeWithSelector(0x69072a9b, uint256(7), uint256(100), uint256(200));

        (bool ok, bytes memory ret) = lib.call(callData);
        assertFalse(ok, "expected the library's own dispatcher to reject a storage-struct-param selector");
        // "unrecognized function selector ... which has no fallback function" — a bare revert (no
        // custom error/reason string), consistent with hitting solc's default dispatcher fallthrough
        // rather than any application-level revert inside the function body.
        assertEq(ret.length, 0, "expected a bare dispatcher-level revert with no returndata");
    }
}
