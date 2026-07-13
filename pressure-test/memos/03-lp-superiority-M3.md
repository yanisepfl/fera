# Memo 03 — M3 LP Superiority (Gates V4 — the whole value prop)

**Verdict: CONDITIONAL PASS.** Regime-fee LPs **strictly beat vanilla on violent/toxic paths**
(the paths that matter), but there are **three conditions** that must be met or V4 is not a
clean PASS. Harness: `harnesses/lp_superiority.py`. Data: synthetic-but-structured (says so);
wire real chain data before the final V4 sign-off. All numbers PRELIMINARY (PARAMS.md, PT-1).

MASTER_SPEC §11: **FAIL if LPs don't strictly beat vanilla.** I do not have a clean strict-beat
across *all* market conditions, hence CONDITIONAL with enumerated fixes, not PASS.

## 1. Method

Backtest a full-range LP (MEME is full-range-never-rebalanced by design) on a price/volume
path, comparing FERA regime fees against vanilla **30bps** and **100bps** pools **net of the
10% performance fee** (charged only on the regime pool; vanilla v3/v4 take no protocol perf fee).

**Key structural insight — IL cancels.** The regime pool and the vanilla pool hold the *same*
position over the *same* path, so their impermanent loss is **identical** and nets out of the
comparison. The entire difference is **fee capture**. So V4 reduces to: *does the regime fee
capture more, net of the 10% perf fee and net of any volume it loses by charging more?*

Two routing models (harness `--elasticity`):
- **Same-volume (`elasticity=0`, PRIMARY):** every pool sees identical volume. Conservative
  **against** FERA — it gifts a static 100bps pool volume it would never win in a routed market.
- **Depth-aware routed (`elasticity>0`, illustrative):** softmin on net price = fee + size/depth.
  Magnitudes are a toy; the **threshold behaviour** is the real result.

MEME fee model: EWMA realized-vol → fee in `[floor, ceil]` with an asymmetric sell-side
surcharge under one-sided flow. RWA fee model: market-hours base + deviation overlay, clamped.

## 2. Results (from `data/last_run.txt`, 200 seeds unless noted)

### MEME, pump/dump paths, same-volume (PRIMARY)
```
regime beats best-vanilla on 200/200 paths (100.0%)
mean edge vs best vanilla: +159.9%   worst path: +156.0%
```
On violent memecoin paths the dynamic fee sits well above the perf-fee hurdle, so LPs capture
far more fee on the *same* toxic volume than a 30bps or 100bps pool. **This is the thesis
working: the more mechanical/violent the flow, the more LPs earn. PASS on the paths MEME lives on.**

### MEME, CALM paths, same-volume (the caveat)
```
regime beats best-vanilla on 0/200 paths (0.0%)
mean edge: -24.6%   worst: -26.7%
```
**The perf-fee hurdle bites.** The 10% perf fee means regime must charge `> 30bps / 0.90 =
33.3bps` just to match a vanilla-30 pool. The MEME **floor is 30bps**, netting **27bps < 30bps**.
So in genuinely calm markets, regime LPs *lose* to vanilla-30. For memecoins this is a small slice
of time, but it is a real hole → **fix PT-3**.

### MEME, depth-aware routed (why depth is load-bearing)
```
depth_mult = 1 (no depth edge):  regime loses ~100% of the toxic flow  -> adversely selected
depth_mult = 3 (3x TVL):         regime keeps flow and wins on every path
```
With no depth advantage, a net-price router sends the high-fee toxic swaps to the cheaper
vanilla pool — the regime pool is **adversely selected**, keeping flow only when its fee is low.
A depth advantage (~2–3x, emissions-bootstrapped TVL) flips it: the regime pool offers a better
*net* price despite the higher fee, so it keeps the toxic flow it prices high. **Fee superiority
is necessary but NOT sufficient — depth is a V4 dependency → fix PT-4.**

### RWA, weekend + Monday open, same-volume
```
regime beats best-vanilla on 0/100 weekends (vs the max() of both tiers)
mean edge vs vanilla-30 : +139.7%   <-- realistic competitor
mean edge vs vanilla-100: -28.1%    <-- unrealistic static-100bps artifact
```
Versus the **realistic** competitor for a liquid 24/7 stock token (a 5–30bps pool), the RWA
regime wins decisively: it charges near-zero in-hours (keeping elastic flow) and ramps the
overlay to the ceiling on the fee-**inelastic** weekend-drift arb and Monday-gap volume,
converting weekend drift from LP *loss* into LP *income*. It "loses" only to a hypothetical
static 100bps pool that is assumed to keep all in-hours volume — which no router would send it.

## 3. Verdict logic

| Condition | Status | Gate |
|-----------|--------|------|
| Strictly beats vanilla on violent/toxic paths | **PASS** (200/200 MEME; RWA vs vanilla-30) | core V4 |
| Strictly beats vanilla in calm markets | **FAIL** (27bps < 30bps at floor) | needs PT-3 |
| Keeps routed flow at a fee premium | **CONDITIONAL** (needs ~2–3x depth) | needs PT-4 |

**Overall V4: CONDITIONAL PASS** — proceed to param freeze **only if** PT-3 (perf-fee hurdle
vs MEME floor) and PT-4 (depth dependency) are adopted, and the test is re-run on **real chain
data across ≥2 real weekends incl. Monday opens** (currently synthetic).

## 4. Required spec changes (logged in OPEN_DECISIONS)
- **PT-3:** raise the MEME fee floor to ≥ ~34bps **or** formally accept documented calm-market
  underperformance vs vanilla-30 and rely on the routed depth edge. (Recommendation: raise the
  floor — a clean strict-beat is worth ~4bps of floor; calm memecoin volume is small anyway.)
- **PT-4:** treat emissions→TVL→depth as a V4/routing dependency and quantify the minimum depth
  multiple per target pair (≈2–3x in the toy; measure for real). Without it, V4's fee win does
  not translate into captured flow.
- **PT-1:** re-run once PARAMS.md freezes the fee curve; the strict-beat margin is sensitive to
  the floor, the vol→fee slope, and the overlay `k`.

## 5. Real data needed next (to convert CONDITIONAL → PASS)
1. Real MEME `Swap` series for ≥3 top RH-Chain memecoin pairs incl. a real pump/dump.
2. Real Stock-Token pool price + Chainlink feed + swap series across **≥2 real weekends incl.
   the Monday open** (V4 explicitly requires this).
3. Incumbent vanilla-pool depth over the same windows (to run the depth-aware routing for real,
   replacing the toy magnitudes).
4. Frozen PARAMS.md fee curve.
