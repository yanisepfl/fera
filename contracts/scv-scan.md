# SCV Audit — Universal 24h Withdrawal-Delay Queue

**Scope:** `src/libraries/VaultQueue.sol` (escrow/settle/burn + flag/resolve/cancel) and the
`FeraVault` wrappers (`requestWithdraw`, `requestWithdrawSingle`, `claimWithdraw`, `flag`,
`resolveFlagged`, `cancelWithdraw`, `setWithdrawGuardian`) in `src/FeraVault.sol`, plus the
share primitive `src/shares/FeraShare.sol`.
**Method:** scv cheatsheet sweep (Pass A grep + Pass B semantic), slither 0.11.3 static analysis,
and a manual adversarial pass focused on the solvency invariant, access control, reentrancy/CEI,
and the pause-freezes-claims semantics.
**Compiler:** `^0.8.26` (checked arithmetic; no `unchecked` in the money path except the safe
`balanceOf[to] += amount` in FeraShare).

## Verdict

**No Critical / High / Medium findings.** The queue is **solvent by construction** — settlement pays
`floor(mulDiv(currentHolding, escrowedShares, currentTotalSupply))` per leg and burns the escrow as
the assets leave, so a claim can never remove more than its live share (proven by the fuzzed
`WithdrawQueueSolvency_PoC`, 512→5000 runs, and by the four invariant assertions therein). Access
control, CEI ordering, and delay enforcement are correct. The remaining items are informational /
documented trust assumptions.

## Findings

### 1. Unchecked ERC-20 return values in VaultQueue — Informational (not exploitable)

**File:** `src/libraries/VaultQueue.sol` L94 (`transferFrom`), L197/L229 (`burn`), L273/L291 (`transfer`)
**Severity:** Informational

`VaultQueue` calls `IFeraShare.transferFrom/transfer/burn` without checking the boolean return.
Slither flags this (`unchecked-transfer`). It is **not exploitable here**: `FeraShare._transfer`
(`FeraShare.sol:148`) debits `balanceOf[from] -= amount` under checked arithmetic, so it **reverts**
on any insufficient balance/allowance and only ever returns `true` on success; `burn` is `onlyVault`
and likewise reverts on underflow. There is therefore no "silent false" path.

**Recommendation:** Optional — for defense-in-depth against a future share implementation, wrap in
`SafeERC20` or `require(ok)`. No change required for the current, known FeraShare.

### 2. Interaction-before-effect ordering in `request` — Informational (mitigated)

**File:** `src/libraries/VaultQueue.sol` L94–L110
**Severity:** Informational

`request` performs the escrow `transferFrom` (L94) *before* writing `requests[reqId]` (L97). This is
a checks-effects-interactions deviation. It is **not exploitable**: `FeraShare` has **no transfer
hook / callback** (`_transfer` only moves balances and emits — `FeraShare.sol:148-157`), so the
`transferFrom` cannot re-enter, and the `requestWithdraw` wrapper is `nonReentrant`. Even a
hypothetical re-entrant caller would find `requests[reqId].owner == 0` and revert `UnknownRequest`.

**Recommendation:** Optional hardening — record the request struct before the escrow transfer. Safe
as-is given FeraShare's no-hook guarantee.

### 3. Guardian can freeze pending withdrawals (griefing) — Low (intended, bounded)

**File:** `src/libraries/VaultQueue.sol` L247–L253 (`flag`); wrapper `FeraVault.sol:410`
**Severity:** Low (documented trust assumption)

A malicious or compromised `withdrawGuardian` can `flag` any pending request, freezing it; a flagged
request cannot be claimed **and cannot be self-`cancel`ed** (L289). This is the *intended* incident
mechanism, and it is **bounded**: the guardian can only freeze — never seize, redirect, or burn
(no asset movement in `flag`) — and the **owner (timelock) always resolves** via `resolveFlagged`
(release, or return the escrowed shares to the user). Funds can never be permanently trapped by the
guardian.

**Recommendation:** Keep the guardian on a tightly-scoped key; document that its only power is a
time-bounded freeze that the timelock overrides. (Already reflected in the NatSpec.)

### 4. `claimWithdraw` is pausable — reverses legacy INV-11 — Low (deliberate)

**File:** `src/libraries/VaultQueue.sol` L145 (`if (p.paused) revert ClaimsPaused()`); `FeraVault.sol:391-396`
**Severity:** Low (deliberate design change — must be documented)

The vault pause now freezes **claims** (not just deposits/strategy). This **reverses the old INV-11**
("withdrawals are never pausable"). It is the point of the circuit-breaker: during a confirmed
exploit, pausing freezes every matured claim so an attacker's queued claims cannot settle.
`requestWithdraw` stays open. The residual risk is owner (timelock) trust — a malicious pause could
delay exits — which is the accepted tradeoff for the incident-response capability.

**Recommendation:** Update the spec/risk register: INV-11 changes from "withdrawals never pausable"
to "**claims** pausable as the incident circuit-breaker; **requests** always open; the owner is a
timelock." (Tracked for the docs pass.)

### 5. flag-vs-claim race at maturity — Informational (mitigated)

**File:** `src/libraries/VaultQueue.sol` L126–L145
**Severity:** Informational

`claimWithdraw` is permissionless; at exact maturity a guardian `flag` and an attacker `claim` race.
Mitigated by design: the guardian has the **full 24h delay** to detect and flag *before* maturity,
and the vault **pause** is an instant, race-free backstop that freezes all claims at once.

**Recommendation:** Operationally, flag during the delay window (not at the last block); rely on pause
for a confirmed incident. No code change.

### 6. Unknown `reqId` builds ctx before reverting — Informational

**File:** `src/FeraVault.sol:397-404`
**Severity:** Informational

`claimWithdraw` derives `id/t` from `withdrawRequests[reqId]` and builds `_vaultCtx(id,t)` before
`VaultQueue.claim` reverts `UnknownRequest` for a never-issued `reqId`. Correct outcome (reverts),
minor gas waste on an invalid call. No fix needed.

## Non-findings verified (swept, no issue)

- **Solvency / over-extraction** — floor `mulDiv`, rounds against the withdrawer (R-17); denominator
  is the current `totalSupply` including the still-escrowed shares; `VaultFees.checkpoint` mints/burns
  **no** shares (perf fee taken as assets), so the denominator is stable across the checkpoint.
- **Reentrancy (eth / no-eth)** — none. Slither's queue hits are all `reentrancy-events` (event after
  call); `r.settled` / `settled` is set before every external interaction (CEI), wrappers are
  `nonReentrant`, and FeraShare has no callback.
- **Access control** — `flag` = `onlyGuardian`; `resolveFlagged` / `setWithdrawGuardian` = `onlyOwner`;
  `cancelWithdraw` checks `caller == r.owner`; `claim` is permissionless but pays `r.owner` only.
- **Double-settle / double-spend** — `settled` guard is terminal and checked at entry of
  claim/cancel/resolve; escrowed shares leave the user's wallet (can't transfer or re-request).
- **Precision** — multiply-before-divide throughout; no division-before-multiplication; no rounding
  that favors the withdrawer. Underflow on `pending/reserve` debits impossible (`share ≤ totalShares`).
- **Timestamp dependence** — 1h cooldown / 24h delay are large windows; validator ±15s is irrelevant.
- **Downcast** — `uint64(block.timestamp)` safe for ~10^13 years.
- **Signature / randomness / delegatecall-to-untrusted / arbitrary-storage** — N/A to this surface
  (the only delegatecalls are to the vault's own trusted libraries; no user-supplied target).
- **Trapped funds** — impossible: `cancelWithdraw` lets the owner reclaim escrowed **shares** (no
  assets, no delay bypass) if a slippage bound can never be met and the request was never flagged.

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0     |
| High     | 0     |
| Medium   | 0     |
| Low      | 2     |
| Info     | 4     |

Both Low items (#3 guardian freeze, #4 pausable claims) are **intended design** — the incident
circuit-breaker the feature exists to provide — bounded by owner-timelock trust and the "guardian can
never seize" property. The action item is documentation (INV-11), not a code fix.
