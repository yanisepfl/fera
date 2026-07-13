# FERA — Integration & Go/No-Go Memo #01

**Author:** Orchestrator (Agent 0). **Date:** 2026-07-11. **Covers:** the first full fan-out
(all 8 workstreams) and its integration into `MASTER_SPEC.md`. **Verdict:** foundations
**GREEN**; mainnet **NO-GO** (as expected at this stage) pending the verification gate and two
decisions below.

---

## 1. What exists now (independently inventoried on disk)

| Workstream | Deliverable | On disk | Self-test status (agent-reported) |
|------------|-------------|---------|-----------------------------------|
| 0 Orchestrator | `MASTER_SPEC.md`, `RISK_REGISTER.md`, `SHARED_CONTEXT.md`, this memo | ✅ 17 docs | — |
| 5 Chain/Deploy | `docs/CHAIN.md` + `docs/deployment/` | ✅ | VERIFIED vs UNVERIFIED table; hook flag `0x2AC0` confirmed |
| 1 Mechanism | `docs/mechanism/` spec + `PARAMS.md` (72 keys) + 5 sims | ✅ | **5/5 sims PASS** on Py3.12 |
| 8 Pressure-Test | 7 memos + 3 harnesses + `RESULTS.md` | ✅ 16 files | harnesses run; **1 CRITICAL, several CONDITIONAL** |
| 2 Contracts | Foundry: 25 src + 13 test (`3,648` Sol LOC), CI, THREAT_MODEL, SPEC_CONFORMANCE | ✅ | **`forge build` PASS; 60 tests pass / 0 fail** |
| 4 Backend | Ponder indexer + api + pipeline + keepers + ops (58 files) | ✅ | **`tsc` exit 0; pipeline dry-run deterministic** (`0xd184…`) |
| 3 Frontend | Next.js app, 5 sections, DESIGN.md (65 files) | ✅ | tsc blocked on `npm install` (deps absent); imports statically verified |

*Confirmation level:* file trees and doc presence independently verified by the Orchestrator.
Build/test PASS results are agent-reported and will be reconfirmed in CI (Deployment 5) — not
yet independently re-run here (heavy builds; deferred to CI to avoid the sandbox stalls that
already killed three agents once).

## 2. Cross-agent validation highlights (the system worked)

- **Mechanism sims clear V4 internally:** MEME LP nets **+7.51%** vs vanilla-30's +1.79% on a
  pump/dump; RWA **+0.35%/wk** vs vanilla's −0.55%/wk; wash net-negative at flat FERA; stakers
  never structurally out-earn LPs.
- **Contracts fuzzer caught a real bug:** `FeeLogic._memeFee` overflowed on extreme volatility,
  violating INV-2 ("swaps never revert") — fixed (saturate vol at 1 WAD) and regression-guarded.
- **Backend pipeline is reproducible:** deterministic Merkle root, byte-identical across runs —
  the §9 "anyone can recompute the root" property holds in the dry-run.
- **Pressure-Test found a genuine economic hole** in the LOCKED token design (R-14, below) — the
  red team did exactly its job before a line of value was at risk.

## 3. Verification gate (MASTER_SPEC §11) — current state

| Gate | State | Note |
|------|-------|------|
| V1 routing (solvers/1inch) | **CONDITIONAL — untested** | Needs a ≤$5k mainnet pool + keys. Runbook ready (`pressure-test/memos/01`). Blocks mainnet. |
| V2 interface auto-route | **CONDITIONAL — untested** | Same live test; hinges on whether RH-Chain Uniswap routing uses a hook allowlist. |
| V3 flow census | **CONDITIONAL** | Method specified; needs chain `Swap` history. Real finding: the ~2026-09-29 gas-holiday cliff. |
| V4 LP superiority | **CONDITIONAL PASS** | Mechanism sims PASS; Pressure-Test confirms on violent paths (+160%) but flags calm-market loss vs vanilla-30 (PT-3) and depth-dependency (PT-4). Needs real chain data to convert to a clean PASS. |

## 4. BLOCKING items before parameter freeze (must clear, in priority order)

1. **R-14 / INV-13 — boost-concentration wash-farm (CRITICAL).** See Decision B below. Blocks
   the emissions param freeze. Currently failing on synthetic data.
2. **DM-6 — 5 PROVISIONAL params** (MEME slope/σ0/λ, RWA band half-width, oracle staleness)
   need V3/V4 real-chain data before Contracts freezes constants.
3. **PT-3 — MEME floor vs perf-fee hurdle:** raise floor to ≥~34bp or accept documented
   calm-market underperformance + the pool-eligibility rule. Mechanism to decide.
4. **D-7 — Uniswap v4 addresses unverified.** Blocks freezing external immutables. Deployment
   confirms on-chain at deploy.

## 5. Decisions required from the principal (raised now)

- **Decision A — cold-start funding (DM-2).** Revenue-gating means only ~11% of the usage bucket
  emits in 4yr, so usage emissions can't fund the TVL cold-start. Provisionally resolved as
  "war-chest funds it; emissions are steady-state," but this reshapes the GTM narrative — needs
  sign-off.
- **Decision B — R-14 boost fix direction.** Which way to close the self-boost wash-farm, so
  Mechanism can re-derive the exact parameters.

*(Both posed to the user alongside this memo.)*

## 6. Reconciliation follow-ups (non-blocking, next session)

| # | Item | Owner |
|---|------|-------|
| F-1 | Add `PoolRegistered(poolId, token0, token1, regime)` event to `FeraHook.beforeInitialize` (BK-2) so the indexer stops env-sourcing pool metadata; add to §6. | Contracts → Backend |
| F-2 | Repoint `backend/abis/*` at `contracts/out/*.json` and diff assumed fragments (BK-1). | Backend |
| F-3 | Implement `GET /vesting/:account` (FE-6, added to §8 v0.2). | Backend |
| F-4 | Align `EsFera._routeForfeit` rounding remainder with `PARAMS.md#FORFEIT_BURN_FRAC` (burn, not revenue) — ≤2 wei, cosmetic (REC-2). | Contracts |
| F-5 | Complete runtime stubs: Vault `_cbRebalance`/`_settleAll` settlement, hook `_poolPriceX96`/`_oraclePriceX96`/`_updateEwma`, `_isMarketOpen` on-chain calendar. deposit/withdraw/collect are already runtime-complete. | Contracts |
| F-6 | Re-run Pressure-Test harnesses against the now-frozen `PARAMS.md` (PT-1) to convert PRELIMINARY verdicts to real ones. | Pressure-Test |
| F-7 | `npm install` + real `tsc`/`next build` for frontend; `slither`/coverage in CI. | Deployment |

## 7. Next-session priorities

1. Resolve Decisions A & B; Mechanism re-derives the boost fix (Decision B) and freezes PT-3/PT-7/PT-8-10 params.
2. Contracts land INV-13/PT-6 real enforcement + F-1/F-4/F-5; re-freeze `FeraConstants`.
3. Deployment stands up the anvil-fork + testnet environments and the CI gates (F-7).
4. Pressure-Test runs F-6 and scopes the live V1/V2 mainnet routing test (needs a funded key).
5. Security (6) opens: co-sign the extreme-deviation circuit (DM-3) and the R-14 fix; start the attack-PoC suite against the compiled contracts.

---

**Bottom line:** the skeleton is coherent and every shared interface is reconciled into
`MASTER_SPEC.md` (now v0.2). One real economic flaw and a cold-start reframing are the two
things that need a human call; everything else is sequenced engineering.
