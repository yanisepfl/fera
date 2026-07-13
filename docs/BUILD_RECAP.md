# FERA — Build Recap

**As of 2026-07-13.** Single source of truth: [`MASTER_SPEC.md`](MASTER_SPEC.md) (v0.6) +
[`RISK_REGISTER.md`](RISK_REGISTER.md). This recap is a map, not the law.

---

## 1. What FERA is

Regime-aware liquidity infrastructure on Robinhood Chain: **one flagless Uniswap v4
dynamic-fee hook** (open swaps + open liquidity) + **one managed Vault** (shaped band ladders,
risk classes, drip recentering) + **a usage-only emission token whose issuance can never exceed
protocol revenue**. It competes for the chain's already-routed volume by making managed LPs
earn well while monetizing toxic/bot/weekend flow through fees that price it, instead of
bleeding to it.

## 2. What got built (from an empty directory)

| Component | Path | State | Scale |
|-----------|------|-------|-------|
| Master spec + risk register + memos | `docs/` | Living, v0.6 | 47 docs |
| Mechanism spec + 9 Python sims + PARAMS (97 keys) | `docs/mechanism/` | Frozen (5 params provisional pending V3/V4) | 16 files |
| Chain due-diligence | `docs/CHAIN.md` | VERIFIED/TODO tagged | — |
| **Contracts** (hook, vault, token, escrow, emissions, distributor, staking, revenue, treasury) | `contracts/` | **`forge build` green; 138 tests pass / 0 fail** | 25 src + 25 test, **8,889 Sol LOC** |
| **Backend** (Ponder indexer, §8 API, deterministic emissions pipeline, keepers, ops) | `backend/` | `tsc` clean; pipeline dry-run deterministic | 61 files |
| **Frontend** (Next.js, 5 sections, design system) | `frontend/` | In-family design; final protocol state | 71 files |
| Pressure-test memos + harnesses | `pressure-test/` | 6 missions, PASS/FAIL verdicts | 16 files |
| Security audit (3-pass) + PoCs + hardening | `security/` | Internal loop **converged** | 17 files |
| GTM (positioning, TVL-seeding, grants, listings) | `docs/gtm/` | Programs web-verified | 5 files |
| Deployment (CI, deploy order, infra, runbooks) | `docs/deployment/` + `.github/` | CI gates + 11-step deploy | 6 files |
| User docs | `docs/user/` | 8 docs, honesty-swept | 8 files |

## 3. The design journey — decisions that shaped it

The mission pack was the starting point; the design moved materially from it. Key decisions
(all logged in MASTER_SPEC §13):

- **Vault storage** — collapse N users into shares over pooled positions (O(pools) state).
  v1's *single full-range position* was **rejected by the principal** as intolerable; replaced
  by **shaped band ladders (≤5 discrete bands) + risk classes (Core/Anchor) + drip recentering**
  (principal never churned; fee income follows price; a rare *guarded* recenter only after depth
  degrades). See [`VAULT_ARCHITECTURE.md`](VAULT_ARCHITECTURE.md).
- **Open liquidity (D-11)** — the hook no longer gates LPing; anyone can LP directly (free depth
  for our pool); **emissions are the vault's exclusive carrot**. The before-liquidity hooks were
  repurposed into a **fee-forfeiture anti-JIT guard** (early exit forfeits accrued fees to LPs
  who stayed; removals never blocked).
- **Emission split → 85/5/10 (LP/trader/treasury)** — optimizer-confirmed; LP-maximal, trader
  slice minimized for wash-safety, treasury kept as the cold-start war-chest.
- **Boost → LP emissions only**; the wash-farm hole closed structurally via within-pool
  emission normalization + funding-cluster self-match exclusion.
- **Honest constraints adopted:** early usage-emissions can't fund cold-start (DM-2) → war-chest
  seeds TVL; the vault does **not** out-yield self-managed LPing (D-M13) → sold on management +
  emissions + simplicity; no "tranche"/"dividend"/"guaranteed yield" in user copy.

## 4. The security story (this is the part that matters)

Three independent audit passes, each catching what the prior structurally couldn't — every
Critical/High closed with a non-tautological regression test:

| Pass | Method | Caught & fixed |
|------|--------|----------------|
| 1 | Custom red-team (hand PoCs) | **R-18** vault deposit-NAV over-mint (Crit): attacker +120%/cycle → now −2 wei |
| 2 | Pashov-style skills (`solidity-auditor`+`scv`) | **R-20** EsFera instant-exit drain (Crit): 100-vest paid 190 → now ≤100; **R-21** staking reward-debt (High) |
| 3 | Convergence pass | **N1/N2** staking crowd-out + poison-token (both High) — one *introduced by the naive residual fix*, caught before shipping |
| Hardening | Coverage + property tests + slither + skill spot-check | +3 cross-contract invariant suites; slither 0 new highs; no new Crit/High |

Also: emissions economics independently **co-signed** (wash-farming is provably dominated by
just buying the token); R-12 first-depositor **safe**; hook swap-path gas **measured ~15k ≤ 40k**.

**Verdict: internal audit loop converged — no open Critical/High. Repo is 0-red.**
Lesson banked: coverage must span *every* money-path contract (the skill audit caught the
EsFera/staking bugs the hand-PoCs never reached).

## 5. Readiness & what's left

**Ready for external audit** (Sherlock contest + boutique — the real code gate). Before mainnet:

- **Standing market gates (not code):** R-1/R-2 — routing (V1/V2) + LP-superiority (V4) need
  **real-chain data**; these are the two existential *market* risks. R-8 legal review.
- **Punch-list (non-blocking, before/at audit):** COV-1 (lift money-path branch coverage to
  100% once the oracle/EWMA scaffolds are wired), SEC-7 Low (EsFera→SafeERC20), external
  re-review of the AnchorStaking curation admins, freeze the 5 provisional params against V3/V4.
- **Ops:** the 11-step CREATE2 deploy order (`docs/deployment/DEPLOY_ORDER.md`), Safe multisig
  on keeper+poster+treasury, 2-week unattended testnet run + 3 dry-run emission epochs (DoD §14).
- **Blocking dependency:** confirm the canonical Uniswap v4 addresses on-chain (D-7) before
  freezing immutables — gated in `mainnet-deploy.yml` preflight.

## 6. Open decisions still owned by the principal

- Trim split to 85/5/10 → **done** (or revert if desired).
- Everything else is either decided (§13) or gated on external data.

## Change log
- 2026-07-10 → 07-13 — Built from the FERA Mission Pack v2 via orchestrated subagents; all 8
  mission-pack workstreams + vault review + 3-pass security loop + hardening complete.
