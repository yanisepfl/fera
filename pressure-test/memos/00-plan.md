# Memo 00 — Pressure-Test Plan & Gate Map

**Author:** Agent 8 (Pressure-Test / Validation). **Date:** 2026-07-10. **Status:** living.
**Role:** red team for economics & market assumptions. Output = numbered memos, each with
data + method + a PASS / FAIL / CONDITIONAL verdict. I try to falsify FERA before the market
does. I build no product.

> **Session constraint:** no funds/keys → no live mainnet tests this session. Live missions
> (M1) ship as an exact runbook + measurement plan + FAIL criteria + fallbacks. Economic/data
> missions (M3–M6) ship as runnable harnesses over synthetic-but-structured data, wired to
> accept real Robinhood Chain data later.
>
> **Global dependency (BLOCKER PT-1):** `docs/mechanism/PARAMS.md` does not exist. Every
> numeric verdict here uses structural defaults from SHARED_CONTEXT and is **PRELIMINARY**
> until Mechanism (1) freezes PARAMS.md and the harnesses are re-run.

## How my verdicts gate Orchestrator milestones (MASTER_SPEC §11 V1–V4)

MASTER_SPEC §11 rule: **V1–V4 resolved before Contracts freeze parameter *values*; V1–V2
before any mainnet deploy.** A Pressure-Test FAIL must be answered in writing before proceeding.

| Gate | Question (MASTER_SPEC §11) | Blocks | My mission(s) | Deliverable | Verdict source |
|------|---------------------------|--------|---------------|-------------|----------------|
| **V1** | Do UniswapX solvers + 1inch route to a flagless hooked v4 pool when price is better? | Mainnet deploy | **M1** | memo 01 runbook (live test, not runnable this session) | live test PASS/FAIL criteria in 01 |
| **V2** | Does the Uniswap interface auto-route our pools (incl. RWA-majors review)? | Mainnet deploy | **M1** | memo 01 runbook | live test criteria in 01 |
| **V3** | Bot/farm vs organic share of memecoin volume (fee calibration input). | Fee freeze | **M2** | memo 02 census method + post-holiday risk | method + synthetic quantification |
| **V4** | Do regime-fee LPs strictly beat vanilla v3/v4 net of 10% perf fee (incl. a real RWA weekend)? | **Whole value prop — param freeze** | **M3** | memo 03 + `lp_superiority.py` | harness PASS/FAIL |

Supporting adversarial missions (not §11 gates, but gate audit sign-off / DoD §14):

| Mission | Scope | Deliverable | Gates |
|---------|-------|-------------|-------|
| **M4** | Token/emission attacks (wash, TWAP, quality, boost, staking raid) | memo 04 + `wash_bot.py` | Emissions param freeze; Security sign-off |
| **M5** | RWA vault adversarial scenarios; fail-static verification | memo 05 + `rwa_stress.py` | RWA strategy bounds freeze |
| **M6** | Competitive/macro war game (fork, protocol fee, gas-holiday end, volume collapse) | memo 06 | Strategy — informs what to build NOW |

## Gate logic (what I hand the Orchestrator)

```
                 ┌─────────────── V1/V2 (M1) ── FAIL ──> DO NOT DEPLOY MAINNET
                 │                              PASS ──> allowlist/solver work only if V2 conditional
 param freeze ◄──┤
                 ├─────────────── V3 (M2) ───── informs fee-curve calibration (no viability veto)
                 │
                 └─────────────── V4 (M3) ── FAIL ──> VALUE PROP UNPROVEN — no param freeze
                                            PASS ──> proceed, with M4/M5 CONDITIONALs folded in
```

- **A single FAIL on V1, V2, or V4 halts the milestone it gates.** V3 never vetoes (we
  monetize bot and organic flow); it only calibrates.
- **CONDITIONAL** = proceed only if the listed spec changes are adopted; each CONDITIONAL
  enumerates the exact change and logs it in `OPEN_DECISIONS.md`.
- I re-run every harness and re-issue verdicts the day PARAMS.md is frozen.

## Preliminary verdict board (full detail in each memo; summary in RESULTS.md)

| Mission | Gate | Preliminary verdict | One-line reason |
|---------|------|---------------------|-----------------|
| M1 | V1/V2 | **CONDITIONAL** (untestable this session) | Design routes by construction (flagless hook = open swaps); must be proven live; fallbacks specified. |
| M2 | V3 | **CONDITIONAL / informational** | Classifier method sound; post-gas-holiday volume cliff is the real risk to quantify with real data. |
| M3 | V4 | **CONDITIONAL** | Regime strictly beats vanilla on violent/toxic paths, BUT loses to vanilla-30 in calm markets (perf-fee hurdle) and needs a depth advantage to keep routed flow. |
| M4 | token | **FAIL (preliminary)** | Base wash claim holds at flat FERA, but **2x self-boost** and **FERA appreciation >39%** make wash-farming profitable; cheapest attack cost/profit ≈ 0.5–5x ≪ 10x. |
| M5 | RWA | **CONDITIONAL** | All scenarios fail-static (bounded), but a 20% Monday gap costs ~3.7–9.25% of TVL; needs off-hours withdrawal + a min-recenter-interval. |
| M6 | strategy | **CONDITIONAL** | Survivable, but a fast-follower fork + a Uniswap v4 protocol fee are the structural threats; moat must be depth+token+data, not the hook code. |

**Biggest existential risk found this session:** M4 boost-concentration — the token flywheel
can be turned into a subsidized FERA-accumulation machine by a self-dealing, self-boosting
whale. Details and fixes in memo 04. **Answer required in writing before emissions param freeze.**
