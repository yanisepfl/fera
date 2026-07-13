# RESULTS — Harness Runs & Verdict Board

**Run:** 2026-07-10T20:51Z · Python 3.12.7 · numpy 2.4.2 · pandas 3.0.1 (macOS).
**Data:** SYNTHETIC-but-structured for every harness (no real chain data wired yet).
**All verdicts PRELIMINARY** until `docs/mechanism/PARAMS.md` is frozen (OPEN_DECISIONS PT-1)
and harnesses are re-run on real Robinhood Chain data. Full captured console output:
`../harnesses/data/last_run.txt`. Reproduce with the commands in `../harnesses/README.md`.

## Verdict board

| Mission | Gate | Verdict | Headline number | Memo |
|---------|------|---------|-----------------|------|
| M1 routing | V1/V2 | **CONDITIONAL** (untestable this session) | design routes by construction; must prove live; fallbacks ready | [01](01-routing-M1.md) |
| M2 flow census | V3 | **CONDITIONAL / info** | day-90 gas-holiday cliff: −20% to −60% MEME revenue | [02](02-flow-census-M2.md) |
| M3 LP superiority | V4 | **CONDITIONAL PASS** | 200/200 violent paths win (+160%); **calm 0/200 (−25%)**; needs ~3x depth | [03](03-lp-superiority-M3.md) |
| M4 token attacks | token | **FAIL** | cheapest profitable attack cost/profit ≈ **0.5x** ≪ 10x | [04](04-token-attacks-M4.md) |
| M5 RWA stress | RWA | **CONDITIONAL** | worst LP drawdown **9.25%** of TVL (Monday gap, q=0) | [05](05-strategy-stress-M5.md) |
| M6 war game | strategy | **CONDITIONAL** | survivable; moat = depth+token+data, not the hook | [06](06-war-game-M6.md) |

## wash_bot.py — M4 (FAIL)
```
[A] self-dealing whole-pool whale, boost=1:
    instant-exit          reward/cost=0.36  net=-0.0640F  PASS
    full vest, g=1.0      reward/cost=0.72  net=-0.0280F  PASS
    full vest, g=1.39    reward/cost=1.00  net=+0.0001F  break-even
    full vest, g=2.0     reward/cost=1.44  net=+0.0440F  FAIL
    -> break-even FERA appreciation over vest = 1.39x
[B] 2x self-boost, minority theta of protocol fees (redistribution attack):
    theta=0.20  reward/cost=1.20  cost/profit=5.00x  PROFIT  FAIL
    theta=0.05  reward/cost=1.37  cost/profit=2.69x  PROFIT  FAIL
    theta=0.01  reward/cost=1.43  cost/profit=2.35x  PROFIT  FAIL
    -> break-even appreciation WITH 2x boost = 0.69x (profits even if FERA falls 31%)
[C] cheapest profitable attack: theta=0.01, boost=2.0, g=2.0
    reward/cost=2.85  cost/profit=0.54x
OVERALL M4 WASH VERDICT: FAIL
```
**Reading:** base "net-negative by arithmetic" claim holds ONLY at flat FERA + no boost
(margin 28%). Breaks under 2x self-boost (steals honest users' emission share) or FERA
appreciation >39%. **Highest-severity finding.** Fix = PT-2/PT-5.

## lp_superiority.py — M3 / V4 (CONDITIONAL PASS)
```
MEME pump/dump, same-volume (PRIMARY):  200/200 win, +159.9% mean edge
MEME calm, same-volume:                 0/200 win, -24.6% (perf-fee hurdle: 27bps<30bps)
MEME routed, depth_mult=1 (no depth):   ~loses all toxic flow (adverse selection)
MEME routed, depth_mult=3 (3x TVL):     200/200 win (depth keeps the flow)
RWA weekend, same-volume:               vs vanilla-30 +139.7% (win); vs static-100 -28.1% (artifact)
```
**Reading:** strictly beats vanilla where it matters (toxic/violent + RWA weekend arb) but
(i) loses to vanilla-30 in calm markets due to the 10% perf-fee hurdle → PT-3, and (ii) needs
a ~2–3x depth advantage or routers adversely select its high-fee flow → PT-4.

## rwa_stress.py — M5 (CONDITIONAL)
```
S1 oracle-halt Friday    NET drawdown 0.30%   FAIL-STATIC (overlay harvests drift)
S2 monday-gap-20%        NET drawdown 3.70% (q=60%) / 9.25% (q=0)   <-- driver
S3 keeper-offline-48h    NET drawdown 0.75%   FAIL-STATIC
S4 tick-grief            0.48%/day (4h min) vs 3.84%/day UNBOUNDED (no min-interval)
S5 mev-sandwich          0.06% randomized vs 0.50% deterministic
WORST: S2 monday-gap at 9.25% of TVL if no off-hours withdrawal.
```
**Reading:** all fail-static (bounded, no fail-open). Monday-gap exposure hinges on off-hours
partial withdrawal `q` (PT-7); tick-griefing needs a min-recenter-interval (PT-6); recenter
timing must be randomized (enforced).

## Open dependencies before verdicts finalize
1. **PT-1** — PARAMS.md frozen (fee curves, β, caps, TWAP window, quality score). Then re-run all.
2. **PT-2/PT-5** — self-boost fix + INV-7 ordering, then re-run `wash_bot.py` targeting every
   cell cost/profit ≥ 10x.
3. **PT-3/PT-4** — MEME floor vs perf-fee hurdle + depth dependency, then re-run `lp_superiority.py`
   on real chain data across ≥2 real weekends.
4. **PT-6/PT-7** — min-recenter-interval + off-hours `q`, then re-run `rwa_stress.py`.
5. Real Robinhood Chain data: `Swap` history, funding graph, Chainlink feeds, incumbent pool depth.
