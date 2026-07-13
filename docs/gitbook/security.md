# Security

FERA is smart-contract software that holds real money, so this page is written the way the rest of
these docs are: **specific and checkable, not reassuring.** The credible posture in DeFi is not
"trust us, it's safe." It's "here is exactly what was reviewed, what was found, and what was fixed,
and here is what still carries risk."

The full working reports live in the repository under
[`security/`](../../security/). This page is the high-level summary.

## The design guarantees that reduce blast radius

These are structural, not promises. They are properties of the deployed contracts:

- **No upgradeable proxies on money paths.** The contracts that hold and move your funds cannot be
  swapped out from under you.
- **Parameters are immutable or timelocked.** Anything adjustable sits behind a **48-hour timelock**;
  the core economics (the 10% performance fee, the fixed 1B token supply, the emission bounds) are
  immutable.
- **Withdrawals and swaps can never be paused.** Pause is allowed on vault *deposits* only, never on
  a withdrawal, never on a swap. Your principal is always returnable; this is enforced as an on-chain
  invariant.
- **Traders and bots pay no protocol fee, and swaps are never blocked** for a fee or (in v1) an
  oracle condition.

## The three-pass internal security review

Before any external process, the money-path contracts went through **three independent security
passes**, each looking for what the previous one might have missed. Every finding was reproduced with
a runnable proof-of-concept or numeric check, fixed, and then locked with a regression test.

1. **Custom red-team (Foundry PoCs).** Standalone attack tests against the real Uniswap v4
   PoolManager + the FERA vault and hook, plus an independent re-derivation of the emissions
   economics. It found the first critical.
2. **Independent skill-based audit (pashov-style gate).** A differently-trained pass over the
   *post-fix* code, cross-referenced against the known findings. It deliberately targeted the
   contracts the red-team had exercised least, and caught two more serious bugs there.
3. **Convergence pass.** A final pass that validated the fixes and hardened the residual
   recommendations, including proving that a tempting "fix" for one issue would have opened a new
   denial-of-service vector (and choosing the safe design instead).

### What was found and fixed

Nothing on this list is open. Each was found by the review, fixed, and covered by a non-tautological
regression test; the full suite is green.

| Area | Issue found | Severity | Status |
|------|-------------|----------|--------|
| Vault deposits | Share price ignored retained fees + off-hours reserve, letting a deposit over-mint and skim existing holders | Critical | Fixed: deposits now price against full vault NAV; round-trip non-dilution fuzzed |
| esFERA exit | Repeated instant-exit could regenerate "locked" balance and drain the shared FERA backing | Critical | Fixed: immutable grant amount + an `exited` accumulator; conservation invariant |
| Staking | Stake/unstake didn't settle reward debt, so a late staker could claim earlier stakers' revenue share | High | Fixed: standard settle-on-stake accounting; per-staker conservation fuzz |
| Staking (reward tokens) | Crowd-out and poison-token denial-of-service on the reward set | High | Fixed: admin-curated reward-token allowlist + per-token harvest isolation |
| Revenue distributor | Unguarded credit could brick pull-based claims | Medium | Fixed: balance-delta guard before crediting |
| Hook TWAP | On ~100 ms blocks the time-window collapsed, weakening the deposit-gate / recenter oracle | Medium | Fixed: time-gated observation ring sized to the real window |

The first-depositor / share-inflation attack (the classic ERC-4626 griefing vector) was tested and
found **safe** by design. Static analysis (Slither) was run and triaged; it surfaced no money-path
vulnerability beyond a low-severity consistency recommendation.

The lesson recorded in the review is worth repeating: **coverage has to span every money-path
contract, not just the vault and hook.** The second pass found the esFERA and staking bugs precisely
because it looked where the first pass hadn't.

## What this does *not* mean

Read this honestly:

- **An internal review is not an external audit.** These passes were rigorous and are fully
  documented in-repo, but an **independent external audit is the recommended final gate**, and it is
  a different and stronger signal than a self-run review. Do not read this page as "audited and
  cleared."
- **Audited, non-upgradeable protocols still get exploited.** Bunni, Gamma, and Cork all shipped and
  still suffered losses. Security work reduces risk; it never removes it.
- **Treat any DeFi deposit as capital you can afford to lose.** That is the correct posture here, no
  matter how much review the code has had.

See [Risks](risks.md#smart-contract-risk) for the plain-language version, and
[`security/`](../../security/) for the underlying reports.

---

Next: [Risks →](risks.md) · [Transparency →](transparency.md)
