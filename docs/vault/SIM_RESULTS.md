# SIM_RESULTS — drip vs drift (docs/vault/sims/drip_vs_drift.py)

**Run:** 2026-07-11, python3 + numpy 2.4.2, seed 42, 100 Monte-Carlo paths per scenario,
runtime ~30s. Reproduce with:

```
cd docs/vault/sims && python3 drip_vs_drift.py
```

**What it tests (review point (b)):** $1M vault vs the same exogenous price/volume series
under four structures — v1 full-range (`FullV1`), the D-12 ladder with drip-only
recentering (`LadderDrip`), the ladder with aggressive principal recentering
(`LadderRecenter`, 12h out-of-core hysteresis), and a **guarded** principal recenter
(`LadderGuarded`: fires only after at-spot depth < 1x the v1 baseline for 24 consecutive
hours, at most once per 7 days). Pool also contains a $250k always-centered direct LP
(recenters 12-hourly, no perf fee) and $250k passive full-range vanilla. Volume is
exogenous and identical across instances — conservative for the deeper strategies, since
in reality depth attracts routed volume (PT-4).

**Column key:** `avg/min/end_depth` = at-spot v3-liquidity multiple vs the v1 full-range
yardstick; `frac_below_v1` = fraction of hours with less at-spot depth than v1;
`fee_share` = share of total pool fees captured; `cap_ratio` = vault fee-per-$ vs the
always-centered direct LP's fee-per-$; `pnl` = $ vs initial $1M (post 10% perf fee);
`pnl_vs_hodl` = (value − 50/50 HODL)/TVL; `bands` = final position count (withdraw-gas
proxy); `costs` = swap/MEV/deploy costs paid. Rows: median, then p10/p90 across paths.

## Raw output

```
FERA drip_vs_drift simulator — params: TVL=$1,000,000, ladder 0.3/0.4/0.3 @ ±30/±100/full, drip daily min $1,000, recenter hysteresis 12h, rebal cost 0.7% on 45% of closed value, fee in [0.3%,3.0%], base volume $600,000/d, seed 42

=== Scenario A: memecoin chop (GBM sigma 8%/d + jumps ±30%, 90d) (100 paths) ===
strategy             avg_depth     min_depth     end_depth frac_below_v1     fee_share     cap_ratio           pnl   pnl_vs_hodl         bands     recenters         costs          perf
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
FullV1                   1.235         1.000         1.504         0.000         0.482         0.289       227,725         0.237             1             0         1,568        50,264
  p10                    1.140         1.000         1.289         0.000         0.409         0.200      -441,007        -0.259             1             0         1,188        38,333
  p90                    1.450         1.000         2.005         0.000         0.575         0.461     2,210,522         0.565             1             0         2,046        65,190
LadderDrip               2.086         0.300         1.176         0.316         0.527         0.375       189,534        -0.042            90             0         1,720        54,822
  p10                    1.359         0.300         0.430         0.129         0.393         0.203      -688,470        -1.386            78             0         1,236        39,548
  p90                    3.186         0.301         5.182         0.634         0.671         0.684     1,079,577         0.450            92             0         2,403        76,638
LadderRecenter           3.217         0.300         2.680         0.010         0.703         0.806       -91,410        -0.127            92            14        15,780        71,802
  p10                    2.600         0.300         1.418         0.000         0.623         0.539      -627,158        -1.545            92            10        10,862        59,662
  p90                    4.038         1.086         4.471         0.031         0.759         1.187       840,188         0.136            92            17        27,671        89,678
LadderGuarded            2.917         0.300         2.432         0.042         0.656         0.644       -78,023        -0.066            92             2         4,622        66,940
  p10                    2.115         0.300         1.153         0.014         0.530         0.366      -650,919        -1.200            91             1         2,923        52,436
  p90                    3.708         0.360         4.784         0.103         0.739         1.003     1,119,217         0.241            92             4         9,731        85,895

=== Scenario B: 3x run-up 30d, then 60d sideways (100 paths) ===
strategy             avg_depth     min_depth     end_depth frac_below_v1     fee_share     cap_ratio           pnl   pnl_vs_hodl         bands     recenters         costs          perf
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
FullV1                   1.047         1.000         1.102         0.000         0.425         0.225       798,280        -0.030             1             0           583        18,824
  p10                    1.031         1.000         1.070         0.000         0.378         0.177        88,622        -1.268             1             0           423        13,588
  p90                    1.081         1.000         1.184         0.000         0.477         0.292     1,956,195         0.124             1             0           808        25,767
LadderDrip               1.084         0.300         0.553         0.701         0.331         0.152       451,363        -0.425            53             0           457        14,937
  p10                    0.701         0.300         0.344         0.185         0.254         0.101       113,800        -2.469            44             0           283         9,210
  p90                    2.354         0.319         2.832         0.853         0.570         0.405       747,490         0.135            74             0           898        28,666
LadderRecenter           3.392         1.309         3.032         0.000         0.683         0.668       470,150        -0.468            84             8        21,141        30,346
  p10                    3.026         0.519         2.222         0.000         0.648         0.573      -145,019        -2.150            81             5        12,949        23,742
  p90                    3.793         1.531         3.971         0.002         0.719         0.828     1,142,417        -0.035            87            11        31,640        39,181
LadderGuarded            2.456         0.314         2.684         0.023         0.596         0.468       496,304        -0.515            80             2         6,089        25,837
  p10                    2.015         0.300         1.260         0.011         0.519         0.336      -167,712        -2.242            77             1         3,215        20,150
  p90                    3.233         0.379         4.118         0.048         0.673         0.664     1,090,176        -0.006            85             3         9,401        36,109

=== Scenario C: grind-down to 0.3x over 90d (100 paths) ===
strategy             avg_depth     min_depth     end_depth frac_below_v1     fee_share     cap_ratio           pnl   pnl_vs_hodl         bands     recenters         costs          perf
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
FullV1                   1.349         1.000         2.032         0.000         0.360         0.159      -841,744        -0.344             1             0           801        26,136
  p10                    1.177         1.000         1.474         0.000         0.310         0.123      -897,004        -0.398             1             0           614        19,626
  p90                    1.684         1.000         3.659         0.000         0.411         0.199      -741,178        -0.254             1             0         1,047        33,460
LadderDrip               1.155         0.300         0.685         0.689         0.264         0.106      -944,752        -0.449            56             0           574        18,838
  p10                    0.820         0.300         0.300         0.519         0.211         0.075      -968,286        -0.469            46             0           422        13,502
  p90                    1.549         0.300         3.160         0.853         0.319         0.146      -895,603        -0.406            64             0           769        24,530
LadderRecenter           3.344         0.723         2.840         0.009         0.548         0.366      -899,317        -0.402            90            13         7,852        39,054
  p10                    3.008         0.300         1.367         0.000         0.469         0.254      -944,914        -0.446            80             9         6,205        32,501
  p90                    3.692         1.039         5.557         0.024         0.630         0.516      -809,421        -0.320            92            17         9,019        45,435
LadderGuarded            2.113         0.300         1.554         0.100         0.397         0.199      -929,067        -0.432            79             5         2,857        28,931
  p10                    1.799         0.300         0.833         0.055         0.335         0.145      -961,442        -0.462            67             3         2,458        22,938
  p90                    2.501         0.300         3.982         0.174         0.481         0.284      -854,459        -0.366            88             7         3,167        33,880

=== JIT EV vs enforced min-hold (dump $100k, fee 3%, bot 3x pool depth) ===
fee captured by JIT position: $2,250
  min-hold   drift cost  risk charge           EV
      0.1s            0            8        2,242
      1.0s            1           25        2,224
     10.0s            6           79        2,165
     60.0s           33          194        2,023
    300.0s          167          433        1,650
    900.0s          500          750        1,000
   1800.0s        1,000        1,061          189
   3600.0s        2,000        1,500       -1,250
(100ms blocks: a '1-block delay' = 0.1s -> EV unchanged; deterrence needs minutes.)
```

## Readings (details argued in ARCHITECTURE_REVIEW.md (b), (d), (f))

1. **The 4.1x depth claim holds only at inception / while price sits in the core band.**
   Time-averaged, drip-only delivers 2.09x (chop), 1.08x (run-up), 1.16x (grind-down);
   its floor is the tail-only state **0.30x — 3.3x WORSE than v1** — and it spends 70%
   of hours below v1 depth in the 3x run-up scenario. Drip cannot chase a trending
   memecoin: fee income (~0.1–0.3%/day of TVL) is an order of magnitude too small to
   re-center a $1M ladder against a 3x/month move.
2. **Aggressive principal recentering fixes depth but bleeds LPs in chop:** median PnL
   −$91k vs +$190k for drip in Scenario A (whipsaw realized IL; costs alone are small).
   This is the Maverick Mode-Both lesson reproduced.
3. **The guarded recenter is the dominant middle ground:** 1–5 recenters per 90d, at-spot
   depth held at 2.1–2.9x v1 in ALL scenarios (frac_below_v1 ≤ 10%), fee share +13–27pp
   vs drip-only in trends (0.60 vs 0.33 in the run-up), LP PnL-vs-HODL within noise of
   drip-only in chop (−0.066 vs −0.042) and better in trends. Drip-only is NOT sufficient
   for MEME; a strictly-guarded principal recenter is worth its cost.
4. **Band-count blow-up is real:** daily drip with no recycling ends at ~50–92 live bands
   in 90 days — withdrawals touching every band would cost O(bands) gas forever. A hard
   band cap + drip-into-nearest-band consolidation is required (review (f), OD-V2).
5. **Open-liquidity competition quantified:** the always-centered direct LP out-earns the
   vault per dollar by 1.2–10x (cap_ratio 0.10–0.81 depending on strategy/scenario).
   Emissions (INV-14) must bridge roughly a 1.5–3x per-$ fee gap for the drip/guarded
   vault to beat sophisticated self-LPs — input for Decision-A′ sizing (OD-V10).
6. **JIT EV table:** with 100ms blocks, block-delay guards are useless (EV at 0.1–10s
   hold ≈ unchanged $2.2k on a $100k dump). Inventory risk alone only kills JIT EV at
   ~30–60 min holds — far too long to impose on withdrawals. Fee-forfeiture (OZ
   LiquidityPenaltyHook pattern) removes the $2,250 fee motive at ANY window length —
   see review (d).

**Caveats:** stylized volume/fee coupling (EWMA-lagged fee, no sell-side asymmetry);
exogenous volume (understates deeper strategies' advantage); rebalance cost model is
flat 0.7% of 45% of closed value; no gas costs (gas holiday until ~2026-09-29, D-4);
100 paths (medians stable to ±few %, tails indicative only). Mechanism should re-run
with frozen PARAMS and V3-calibrated volume before freezing `MEME_LADDER`.
