# FERA Vault Architecture v2 — Adversarial Review

**Author:** Agent V. **Date:** 2026-07-11. **Reviews:** `docs/VAULT_ARCHITECTURE.md`
(D-12, ADOPTED-PROVISIONAL). **Evidence:** `COMPETITIVE_SCAN.md` (sourced),
`SIM_RESULTS.md` + `sims/drip_vs_drift.py` (reproducible, seed 42). Change requests
logged in `OPEN_DECISIONS.md` (OD-V1..V10). This file proposes amendments; it edits
nothing upstream.

Verdict scale: **CONFIRM** (ship as written) / **AMEND** (structure right, stated fix
required) / **REJECT** (wrong, alternative given).

---

## (a) Band-ladder depth math — **CONFIRM** (with one wording amendment)

Recomputed independently (`1/(1 − k^(−1/2))` for a geometric band `[P/k, kP]`, value-
matched at center; derivation: position value at center `= 2L√P(1 − k^(−1/2))`, full-range
`= 2L√P`):

| Band | k | Proposal | Recomputed |
|---|---|---|---|
| ±100% | 2.0 | 3.4x | **3.41x** |
| ±50% | 1.5 | 5.4x | **5.45x** |
| ±30% | 1.3 | 8.1x | **8.13x** |
| ±20% | 1.2 | 11.5x | **11.48x** |
| ±5% | 1.05 | 41x | **41.49x** |
| ±0.5% | 1.005 | ~400x | **401.5x** |

Ladder weighted at-spot depth: `0.30×8.13 + 0.40×3.41 + 0.30×1.0 = 4.106` — the **~4.1x
claim is correct**. Formula, table, and weighting all check.

Two honesty amendments (wording only, OD-V8):
1. **4.1x is the at-center/inception figure.** Once price leaves the core band the ladder
   quotes 1.67x (mid+tail), and outside the mid band **0.30x — 3.3x worse than the v1
   full-range it replaced**. Simulated time-averages: 2.09x (chop) / 1.08x (3x run-up) /
   1.16x (grind-down) under drip-only (SIM_RESULTS #1). Depth superiority is a
   *recentering* property, not a *ladder* property. This feeds (b).
2. Label nit: "±30%" with k=1.3 is geometrically symmetric = **+30% / −23.1%**. Fine for
   prose; PARAMS.md should freeze k (or tick counts), not percentages.

## (b) Drip recentering — **AMEND: drip-only is insufficient for MEME; add a guarded
principal recenter (INV-5″) + no-swap drip**

Sim evidence (SIM_RESULTS, 100 paths/scenario): drip income (~0.1–0.3%/day of TVL) is an
order of magnitude too small to re-center a ladder against memecoin drift.

- **3x run-up (the memecoin base case):** drip-only spends **70% of hours below v1
  depth** (median avg 1.08x, ending 0.55x), captures **33% of pool fees vs 43% for v1
  full-range** — the redesign's own metric (fee-capture share) goes *backwards* vs v1
  exactly when a memecoin does what memecoins do.
- **Chop:** drip-only is the best LP deal (median PnL +$190k vs −$91k for aggressive
  recentering — whipsaw realized IL; Maverick Mode-Both lesson, scan §1.9).
- **Guarded recenter** (fires only when at-spot depth < 1x v1 for 24 consecutive hours,
  ≤1 per 7 days): depth 2.1–2.9x v1 in all scenarios, frac-below-v1 ≤ 10%, fee share
  +13–27pp vs drip-only in trends, LP PnL within noise of drip-only in chop. **1–5
  recenters per quarter.** Dominant on the depth/PnL frontier.

**Amendments:**
1. Replace INV-5′ with **INV-5″**: principal is never moved by strategy *except* the
   guarded recenter: trigger = at-spot depth < `DEPTH_FLOOR_MULT` (default 1.0x v1
   yardstick) sustained `GUARD_PERSIST` (default 24h) — equivalently price outside the
   mid band; constraints = pool-TWAP-vs-execution sanity band, `MIN_RECENTER_INTERVAL_MEME`
   (default 7d; PT-6 analog — the trigger is griefable without it), max-slippage bound,
   randomized keeper timing (§10), event `StrategyAction kind=6 guardedRecenter`. Same
   on-chain-verified-bounds pattern as RWA's INV-6 — no discretion added. Worst case with
   the guard never firing = drip-only = today's proposal; the exception only adds the
   trend case where drip demonstrably fails. (OD-V1; blast radius: MASTER_SPEC §2/§6,
   Contracts, Mechanism params.)
2. **Drip should deploy without swapping** (Charm pattern, scan §1.3): place accrued fee
   income single-sided as a limit band on the excess-token side of spot instead of
   swap-assisting to 50/50 — deletes drip's swap cost and its sandwich surface. The
   "fee income MAY be swapped" clause becomes unnecessary; keeping principal *and* fees
   swap-free makes INV-5″'s "no swap" audit check binary. (OD-V1.)
3. **Fix the band-count blow-up** — see (f); drip must consolidate (OD-V2).

## (c) Risk tranches — **AMEND: 2 is right as a maximum; MEME defaults single-tranche;
salt discipline + fee-checkpoint mechanics must be specified**

- **Is 2 the right number?** Yes as a cap: each tranche multiplies band slots, NAV
  checkpoints, emissions attribution rows, and audit surface; no scanned competitor
  manages even two share classes over one pool (scan table). But **Anchor demand on MEME
  pools is not realistic enough to ship by default**: Anchor ≈ tail/full-range ≈ the v1
  product the principal rejected; sim cap_ratio for full-range in chop is 0.29 (direct
  LPs out-earn it 3.4x per $), and the "conservative memecoin LP" persona is thin.
  Anchor's real customer is RWA ("someone LPing NVDA"). **Ship MEME single-tranche
  (ladder, Core only), Anchor on RWA pools** — the proposal already permits this
  (§2.3); make it the default, pending Mechanism demand evidence (PT-3-style: Anchor
  net APR must beat vanilla-30). (OD-V4.)
- **Per-band fee attribution:** the claim "fees accrue per position, a band belongs to
  exactly one tranche" is **correct in v4** — positions are keyed
  `keccak(owner, tickLower, tickUpper, salt)` and fees accrue per key; the hook receives
  `(sender, tickLower, tickUpper, salt)` in before-liquidity params (verified from
  v4-core `IHooks.sol`; `sender` = initial msg.sender of the liquidity call = the Vault).
  **Caveat the proposal skips:** if two tranches ever hold bands with identical ticks and
  identical salt, v4 *merges* them into one position and fee attribution silently breaks.
  Required: tranche-scoped salt namespace (e.g. `salt = bytes32(tranche, bandSeq)`), plus
  an invariant test that no two live bands share a position key, plus the rule that a
  drip band inherits the tranche of the fee income that funded it. (OD-V6.)
- **Second caveat — v4 auto-collects fees on every `modifyLiquidity`:** any deposit add
  to a band credits that band's accrued fees to the Vault's delta in the same call. The
  proposal's "fee-checkpointed minting" must be specified as: checkpoint/collect fees
  *before* computing the mint NAV, else depositors buy into pre-existing fees (share-JIT
  through the accounting back door). This makes the cooldown-vs-checkpoint choice in
  §2.5 **not** an either/or: the checkpoint is mandatory for correctness; the cooldown
  additionally kills flash-round-trips. (OD-V5.)
- **Cross-tranche fairness at deposit/withdraw:** clean by construction — disjoint band
  sets mean per-tranche NAV shares no state; the only shared surfaces are (i) swap-assist
  execution (bound slippage per tranche), (ii) rounding (adopt the Bunni rounding-direction
  invariant per tranche: mint rounds shares down, withdraw rounds assets down, cumulative
  drift bound fuzz-tested — scan §1.8 lessons 2–3). INV-15 as written is testable; add
  the *cumulative* dust bound (Bunni died from 44 × per-op-dust). (OD-V5/R-17.)
- **"Old cores become tail mass":** functional truth, but they remain **Core-tranche**
  assets. Anchor marketing must not claim "all wide liquidity is Anchor". Wording fix.

## (d) JIT min-hold — **AMEND/REJECT the hard revert: keep the uniform guard, switch the
mechanism to OZ-style fee-forfeiture; the dust-grief is already dead if keyed correctly**

- **Does a min-hold stop JIT under 100ms blocks?** Block-denominated delays: no. JIT EV
  on a $100k dump at 3% fee (bot 3x pool depth): $2,250 captured; inventory-risk cost at
  0.1s/1s/10s holds is ≈$8/$25/$79 — **EV unchanged**. Deterrence via inventory risk
  alone needs **~30–60 min** holds (EV ≈ +$189 at 30 min, −$1,250 at 60 min under
  memecoin post-dump drift assumptions; weaker for hedgeable WETH-major pairs)
  (SIM_RESULTS JIT table). A 30–60 min hard hold on *removes*:
  - collides with **INV-11** (withdrawals never blockable): every vault deposit/drip add
    to a band re-arms that band's clock; any user withdrawal touching the band within the
    window **reverts**. Uniformity (INV-1′) forbids exempting the Vault. This is a
    cross-invariant contradiction in the adopted design as written.
  - punishes legit direct LPs and rebalancing bots (a 12h-cadence recenter is fine, but
    any stop-loss-style exit inside the window bricks), and punishes the RWA strategy's
    own recenter/widen/partialWithdraw ops after a fresh deposit.
- **The fix that keeps the goal and drops the collisions — fee-forfeiture penalty**
  (OpenZeppelin `LiquidityPenaltyHook`, audited, source-verified; scan §1.10): on remove
  within `JIT_WINDOW` of a position's last add, forfeit `accruedFees × (1 −
  elapsed/window)` and **donate to in-range LPs**; principal always exits. JIT profit
  motive = the fees; forfeiting them makes JIT EV ≤ 0 **at any window length**, so the
  window can be short-ish (Mechanism: 10–30 min) without needing to make inventory risk
  do the work. Withdrawals are never blocked (INV-11 restored); early withdrawers lose
  only fees accrued during the window (Veda share-lock precedent). Costs, stated plainly:
  needs `afterAddLiquidity`/`afterRemoveLiquidity` + both RETURN_DELTA flags → **the
  "hook permission bits unchanged 0x2AC0" claim in §2.4 is false under this fix; salt
  re-mining required** (arithmetic carries over, CHAIN.md §7); plus withheld-fee custody
  in the hook (small, auditable, OZ reference implementation exists). Edge: OZ donate
  reverts if no in-range liquidity exists to receive — FERA's tail band makes a recipient
  near-always exist; the "last withdrawer in window" edge case needs a fallback (skip
  donation). If the Orchestrator refuses the flag change, minimum viable alternative:
  keep the before-hooks revert but with **liquidity-weighted hold timestamps** (an add of
  ΔL moves the clock by ΔL/(L+ΔL) of the window) + vault withdrawal routing away from
  in-window bands — workable but strictly more moving parts for a weaker guarantee.
  (OD-V3; Security co-sign D-13.)
- **Dust-add griefing (can an attacker extend/reset someone else's hold?):** with the key
  `(owner=sender, poolId, tickLower, tickUpper, salt)` — **no**. Verified: v4 passes
  `sender` (initial msg.sender of the liquidity call) + `tickLower/tickUpper/salt` to
  before/after-liquidity hooks (v4-core `IHooks.sol`), so the hook keys exactly the
  position; a third party cannot produce the victim's key via direct `PoolManager` calls
  (their `sender` differs), and the canonical v4 `PositionManager` gates
  `increaseLiquidity` with `onlyIfApproved` — added specifically as an audit fix
  (OpenZeppelin v4-periphery audit; scan §1.10). Residual, must be documented: users of
  any third-party periphery that LPs with a shared owner address and constant salt
  co-own one position — one such user's add re-arms the shared clock/withheld fees for
  all of them. Ecosystem caveat, not a FERA bug; frontends should steer direct LPs to the
  canonical PositionManager. The proposal's keying requirement is **CONFIRMED**; encode
  it as an invariant test.

## (e) Deposit NAV pricing + cooldown vs the Gamma vector — **CONFIRM structure, AMEND
with hard parameter bounds (the verified vector was a parameter failure)**

Verified vector (scan §1.2): Gamma's deposit guard *existed* — a TWAP price-change
threshold — but automation misconfigured it to allow −50%/+100% moves (intended ~2%);
flash-loaned price manipulation inside the tolerance + share mint priced off manipulated
reserves = over-minted shares, ≥$4.5M gone. The code was fine; the parameter had no
on-chain floor/ceiling.

FERA's proposal (TWAP/oracle-sanity NAV + cooldown + first-depositor guards) blocks the
vector **only if**:
1. the spot-vs-TWAP deviation gate has **hardcoded bounds** (timelocked within an
   immutable legal range, e.g. gate ∈ [0.5%, 5%]); no keeper/off-chain path can widen it
   (this was Gamma's actual hole);
2. deposits are **ratio-matched** to current band composition (depositor can't pick an
   advantageous single-sided ratio at a manipulated price; swap-assist executes inside a
   slippage bound and the minted shares are priced post-assist);
3. share mint uses **TWAP-valued NAV with the fee checkpoint of (c)** applied first;
4. `DEPOSIT_COOLDOWN_SEC` (Veda share-lock precedent) spans enough blocks that a
   manipulation must be held across FCFS blocks and arbed against, not flash-loaned —
   on 100ms blocks a seconds-scale cooldown is ~free UX-wise; Mechanism sizes it jointly
   with the TWAP window (interacts with PT-8's window work);
5. deposits (pausable, INV-11) revert outside the gate — acceptable UX cost in vol spikes.
Residual risk: MEME pools have no external oracle — the TWAP is the pool's own, so the
gate's window must be long enough to be manipulation-expensive under FCFS/no-priority-fee
sequencing (D-6 helps: no auction to buy block position). (OD-V5.)

## (f) Gas: ≤5 bands × 2 tranches — **AMEND: the ≤5 cap is currently fiction under
never-recycle drip; add a hard band cap + consolidation. Costs otherwise fine**

- **Sketch** (orders of magnitude; Contracts CI must measure — same discipline as the
  ≤40k hook budget): v4 singleton + flash accounting means a multi-band op is one unlock,
  one token-settlement pair, N `modifyLiquidity` calls. Rough per-call: ~80–150k warm
  (+~20–40k when initializing new ticks). Deposit into a 3-band Core tranche ≈
  **350–600k**; 5 bands ≈ 500k–1M; withdraw similar; collect-only (liquidityDelta=0
  poke) ≈ 60–100k/band. Arrakis v2-class vaults historically land 300–600k per
  deposit (LOW confidence benchmark; scan §1.1) — FERA is in-family. On Robinhood Chain
  gas is currently free (holiday to ~2026-09-29) and cheap after; the binding constraint
  is not user gas but **keeper drip/collect cadence post-holiday (D-4)** and the ≤40k
  hook budget (untouched by this review).
- **The real problem:** never-recycled daily drip ends the quarter at **50–92 live
  bands** (SIM_RESULTS #4). Withdrawals burning pro-rata across all bands = O(bands)
  `modifyLiquidity` calls ≈ **5–13M gas** — DoS-adjacent, and it grows without bound.
  The "≤ ~5 bands" header and "band recycling default never" are mutually exclusive
  under drip. Fix (OD-V2): (i) hard `MAX_BANDS_PER_TRANCHE` (suggest 6–8) enforced
  on-chain; (ii) drip **consolidates**: if an existing core-class band's center is
  within ±X% of spot, compound into it (kind=4) instead of minting a new band; (iii)
  define **principal bands vs fee-funded bands** — INV-5″'s no-touch rule protects
  *principal* bands; fee-funded drip bands are, by the invariant's own text, "fee
  income (re)deployed" and MAY be consolidated/recycled by strategy without touching
  the principal guarantee. This dissolves the contradiction without weakening the
  LP-protection story.

## (g) What the competition solves that the proposal misses — four specifics

1. **Surge fees (Bunni):** FERA's EWMA fee lags one-shot jumps — the first dump of a
   quiet pool trades near the 0.30% floor while causing max LP damage; Bunni's surge fee
   answered exactly this with an instant spike + decay. Mechanism should evaluate a
   jump-detector fee bump inside the existing floor/ceiling (no new invariant needed —
   the ceiling clamp already bounds it). Routed to Mechanism via OD-V9.
2. **No-swap rebalancing (Charm) / single-sided limit orders:** free, MEV-immune drip
   deployment — adopted into amendment (b)2.
3. **Fee-forfeit JIT defense (OZ hooks):** strictly better than the adopted hard
   min-hold — amendment (d).
4. **Bounded-parameter deposit guards + share locks (Veda, post-Gamma):** hard bounds
   belong in code, not config — amendment (e).
   Also noted: Angstrom's auction lane stays correctly on the v2 roadmap (don't pull it
   forward; it would compromise open routing), and Cork's hook access-control failure
   belongs in Security's test plan (scan §1.10). And one **non-engineering** miss:
   BarnBridge's SEC order makes "tranche" a loaded word — legal review of Core/Anchor
   framing before GTM (OD-V7).

---

## SUMMARY

| Element | Verdict |
|---|---|
| (a) Ladder depth math / 4.1x | **CONFIRM** (numbers exact; state 4.1x as at-center, not steady-state) |
| (b) Drip-only recentering | **AMEND** — insufficient for MEME trends; add guarded principal recenter INV-5″ (depth-triggered, 24h persist, ≥7d interval, TWAP-checked) + no-swap limit-band drip |
| (c) Tranches | **AMEND** — 2 as max is right; MEME defaults single-tranche, Anchor is an RWA product; tranche-scoped salts + fee-checkpoint-before-mint are mandatory |
| (d) JIT hard min-hold | **REJECT the hard revert / AMEND the guard** — keep uniform anti-JIT, switch to fee-forfeiture (OZ pattern); hard hold either doesn't deter (seconds) or blocks withdrawals (minutes, INV-11 conflict). Dust-grief already dead under per-(owner,ticks,salt) keying — verified |
| (e) Deposit NAV + cooldown | **CONFIRM structure / AMEND params** — Gamma's vector was an unbounded parameter; hardcode gate bounds, ratio-match deposits, checkpoint fees pre-mint |
| (f) Gas / band count | **AMEND** — per-op costs fine; never-recycle drip breaks the ≤5-band model (50–92 bands/quarter, O(bands) withdrawals); hard cap + consolidation + principal-vs-fee-band distinction |
| (g) Missed vs competition | surge-fee lag, no-swap drip, fee-forfeit JIT, hard-bounded guards, tranche-word legal risk |

**Three most important amendments (in order):**
1. **OD-V3 — replace the hard JIT min-hold with fee-forfeiture.** The adopted D-13
   design as written either fails (short hold) or contradicts INV-11 (long hold); this is
   the only finding that breaks an invariant. Accept the flag-set change + salt re-mine.
2. **OD-V1 — INV-5″ guarded principal recenter + no-swap drip.** Drip-only loses the
   depth war (and even the fee-share war vs v1) exactly in the memecoin run-up case the
   product is built for; the guarded version is quantitatively dominant and keeps the
   no-discretion, bounded-keeper model.
3. **OD-V2 — hard band cap + drip consolidation.** Without it, withdraw gas grows
   O(bands) forever and the "≤5 bands" architecture is not what actually ships.

**Competitive headline:** closest neighbor is **Arrakis** — on our chain, on v4, pooled
multi-position vaults — but aimed at token issuers, without tranches, regime fees, or an
emissions flywheel; what kills *us* if we're sloppy is what killed the two nearest
experiments: **Bunni** (withdraw-rounding around shaped liquidity — R-17: rounding-
direction invariant + cumulative dust bound + micro-withdrawal PoC) and **Gamma**
(unbounded deposit-guard parameter — hardcode the bounds). Nobody found combines
regime fees + shaped pooled liquidity + tranches + emissions-gated managed layer.

**Open questions routed onward:**
- *Orchestrator:* accept flag-set change 0x2AC0 → after-liquidity+return-delta set for
  fee-forfeit JIT guard (OD-V3)? Accept INV-5″ (OD-V1)? MEME single-tranche default
  (OD-V4)? Legal review of tranche framing (OD-V7).
- *Mechanism:* freeze `JIT_WINDOW`, `DEPOSIT_COOLDOWN_SEC` + TWAP window (joint with
  PT-8), guarded-recenter params (`DEPTH_FLOOR_MULT`, `GUARD_PERSIST`,
  `MIN_RECENTER_INTERVAL_MEME`), `MAX_BANDS_PER_TRANCHE`, drip cadence/min-size; evaluate
  surge-fee jump bump (OD-V9); size emissions to bridge the measured 1.5–3x per-$ fee
  gap vs direct LPs (OD-V10); Anchor-demand test for MEME (OD-V4).
- *Contracts/Security:* Bunni-pattern micro-withdrawal PoC vs per-tranche accounting;
  no-shared-position-key invariant; Cork-style hook access-control tests; measure real
  multi-band gas in CI.
