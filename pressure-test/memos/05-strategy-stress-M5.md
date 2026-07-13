# Memo 05 — M5 RWA Vault Adversarial Stress

**Verdict: CONDITIONAL.** Every scenario **fails-static** (positions hold; no fail-open path
found in the model) and losses are **bounded**, but a 20% Monday earnings gap costs **3.7–9.25%
of TVL** depending on the off-hours partial-withdrawal fraction, and tick-boundary griefing is
**unbounded without a minimum recenter interval**. Proceed only with the spec changes below.
Harness: `harnesses/rwa_stress.py`. Numbers are order-of-magnitude over synthetic data,
PRELIMINARY (PARAMS.md, PT-1).

## 1. Model (documented approximations)
RWA position = concentrated band, half-width `w` around the Chainlink oracle. Tight band ⇒
concentration ~ `1/(2w)`. When true price gaps `d` past the band edge, the facing inventory
(~50% of TVL) is transacted at ~the band edge, so `band_loss ≈ 0.5·max(0, d−w)` of TVL. The
in-hook deviation overlay (ramps with `|pool−oracle|`, clamped to the ceiling) earns fee on the
crossing arb volume and **offsets** part of the loss. Off-hours partial withdrawal of fraction
`q` scales exposed inventory by `(1−q)`. These bound the risk and force PARAMS numbers; they are
not a tick-exact v3 sim (wire real data — README).

## 2. Scenarios & worst-case LP drawdown (`data/last_run.txt`, w=0.5%, q=60%)

| # | Scenario | Fail mode | NET drawdown | Verdict |
|---|----------|-----------|--------------|---------|
| S1 | **Oracle halt Friday** (3% weekend drift) | FAIL-STATIC — band frozen (INV-6 needs fresh oracle in sanity band); swaps + overlay stay live | **0.30%** | OK — overlay harvests the drift |
| S2 | **20% Monday earnings gap** | FAIL-STATIC — TWAP gate stops recenter *into* the gap (protective) | **3.70%** (q=60%) / **9.25%** (q=0) | **CONDITIONAL — q is load-bearing** |
| S3 | **Keeper offline 48h** | FAIL-STATIC — holds, but forgoes off-hours widen/withdraw | **0.75%** (+0.45% vs widened) | OK — overlay still ramps in-hook |
| S4 | **Tick-boundary griefing** (8bps slippage/recenter) | bounded *iff* min-interval exists | **0.48%/day** (4h min) vs **3.84%/day UNBOUNDED** (no min) | **CONDITIONAL — needs min-interval** |
| S5 | **MEV sandwich of recenter** (10% of depth) | mitigated by randomized timing | **0.06%** (randomized 64 slots) vs 0.50% (deterministic) | OK — randomization REQUIRED |

**Driver: S2 (Monday gap) at up to 9.25% of TVL if the vault does not partially withdraw
off-hours.** This is the dominant RWA risk. The mechanism is inherent: a tight band that is
great for in-hours fee capture is maximally exposed to an overnight/weekend gap. The design's
own answer — "widen/partially withdraw off-hours" (SHARED_CONTEXT §3) — is exactly the mitigation,
but its magnitude is unset (PARAMS.md). At `q=60%` withdrawal the Monday-gap loss falls from
9.25% to 3.7%.

## 3. Fail-static verification
- **INV-6** makes S1/S2 safe against the worst mistake: the vault **cannot recenter into a
  gapped/halted oracle** (recenter reverts unless oracle-moved-past-hysteresis AND market-open
  AND pool-TWAP-within-sanity-band). So it never chases a bad print — it holds. Confirmed
  protective in the model. The residual loss is passive band conversion, not an active bad trade.
- **Keeper absence fails-static** (MASTER_SPEC §10): S3 holds; the only cost is *forgone* off-hours
  widening (+0.45%), because the deviation overlay is **in-hook and keeper-independent** — it keeps
  pricing the deviation even with keepers down. Good defense-in-depth.
- **No fail-open path found** in the model: there is no scenario where a stale oracle, offline
  keeper, or griefer causes the vault to *actively* mint/recenter at an attacker-chosen bad price.

## 4. CONDITIONAL verdicts — required spec changes (logged in OPEN_DECISIONS)
- **PT-7 (S2):** Mechanism must **freeze the off-hours partial-withdrawal fraction `q`** as a
  hard on-chain bound, and add a **known-event forced widen/withdraw** (earnings-calendar-driven)
  so the vault de-risks *before* scheduled high-gap events, not after. Without this, RWA LPs eat
  a recurring ~4–9%-of-TVL Monday tax.
- **PT-6 (S4):** add `MIN_RECENTER_INTERVAL` (keeper-scoped, on-chain enforced) to the RWA
  strategy bounds and MASTER_SPEC §10; without it tick-boundary griefing is unbounded (3.84%/day).
- **S5:** the "randomized timing within window" mitigation (already in §10) must be **mandatory
  and enforced**, not best-effort — deterministic recenters are sandwichable (0.50% vs 0.06%).
- **Band width `w`:** freeze in PARAMS.md; the S2 exposure scales with `1/w` concentration vs
  `(d−w)` gap size — there is a real tension (tight = more in-hours fee, more gap risk).

## 5. Worst-case LP drawdown summary & data needed next
- **Worst case (this model):** S2 Monday gap, **9.25% of TVL** with no off-hours withdrawal;
  **3.7%** at q=60%. Everything else ≤ ~0.8%/event (or ≤3.84%/day for ungated griefing).
- **Data needed:** real Chainlink feed + pool-price + swap series across ≥2 real weekends incl.
  a genuine earnings gap; real recenter gas/slippage from testnet; frozen `w`, `q`, hysteresis,
  TWAP sanity band, and `MIN_RECENTER_INTERVAL`. Re-run `rwa_stress.py`; target every scenario
  bounded and S2 within an accepted LP-drawdown budget.
