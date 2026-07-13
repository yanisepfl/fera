#!/usr/bin/env python3
"""
ladder_guarded_weights.py  --  validate MEME_LADDER weights UNDER the adopted
guarded-recenter policy (D-15 / INV-5'', docs/vault/ARCHITECTURE_REVIEW.md (b)).

Thin wrapper over docs/vault/sims/drip_vs_drift.py (Agent V's reviewed 90d
Monte-Carlo world: hourly steps, EWMA-lagged fee, $250k always-centered direct
LP + $250k passive vanilla in-pool, guarded recenter = depth<1x v1 for 24h,
>=7d apart). We sweep the ladder weights with everything else frozen and run
ONLY LadderGuarded (the adopted policy) on the two scenarios that discriminate:
memecoin chop (A) and 3x run-up (B).

Selection criteria (same lens as ladder_shape.py): Pareto on
(fee_share, pnl_vs_hodl-chop, pnl_vs_hodl-runup, avg_depth), prior 30/40/30
retained unless dominated.

Deterministic (seed 42, inherited). Runtime ~20s at 60 paths.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "vault", "sims"))
import numpy as np
import drip_vs_drift as dvd

N_PATHS = 60
WEIGHT_SETS = {
    "20/40/40": (0.20, 0.40, 0.40),
    "30/40/30 (frozen)": (0.30, 0.40, 0.30),
    "40/40/20": (0.40, 0.40, 0.20),
    "50/30/20": (0.50, 0.30, 0.20),
}
SCENARIOS = [("chop", dvd.path_gbm_jumps), ("3x run-up", dvd.path_runup)]


def run_weights(weights):
    dvd.W_CORE, dvd.W_MID, dvd.W_TAIL = weights
    out = {}
    for sname, pf in SCENARIOS:
        rng = np.random.default_rng(dvd.RNG_SEED)
        rows = []
        for _ in range(N_PATHS):
            prices, r, jmask = pf(rng)
            fee, vol = dvd.fee_volume_series(r, jmask)
            rows.append(dvd.run_instance(dvd.LadderGuarded, prices, fee, vol))
        med = lambda k: float(np.median([row[k] for row in rows]))
        out[sname] = dict(depth=med("avg_depth"), share=med("fee_share"),
                          cap=med("cap_ratio"), pnl=med("pnl_vs_hodl"),
                          rec=med("recenters"), bands=med("bands"))
    return out


def main():
    print("=" * 84)
    print("MEME_LADDER weights under the ADOPTED guarded-recenter policy "
          "(D-15, LadderGuarded)")
    print(f"(drip_vs_drift world, {N_PATHS} paths/scenario, medians; "
          "guard: depth<1x v1 24h, >=7d apart)")
    print("=" * 84)
    results = {}
    for name, w in WEIGHT_SETS.items():
        results[name] = run_weights(w)
    hdr = (f"  {'weights':<20}"
           f"{'depth-A':>9}{'share-A':>9}{'pnlH-A':>9}"
           f"{'depth-B':>9}{'share-B':>9}{'pnlH-B':>9}{'rec-B':>7}")
    print(hdr)
    for name, r in results.items():
        a, b = r["chop"], r["3x run-up"]
        print(f"  {name:<20}"
              f"{a['depth']:>9.2f}{a['share']:>9.1%}{a['pnl']:>9.3f}"
              f"{b['depth']:>9.2f}{b['share']:>9.1%}{b['pnl']:>9.3f}"
              f"{b['rec']:>7.0f}")

    prior = results["30/40/30 (frozen)"]
    dominated = False
    for name, r in results.items():
        if name == "30/40/30 (frozen)":
            continue
        better_everywhere = all(
            r[s][k] >= prior[s][k]
            for s in ("chop", "3x run-up") for k in ("share", "pnl", "depth"))
        if better_everywhere:
            dominated = True
            dom = name
    print("\n" + "=" * 84)
    if dominated:
        print(f"VERDICT: 30/40/30 is DOMINATED by {dom} under the guarded "
              f"policy -- RE-FREEZE.")
    else:
        print("VERDICT: 30/40/30 remains Pareto-nondominated under the guarded "
              "recenter policy: PASS")
        print("  - the guard, not the weights, carries trend depth (recenters "
              "re-anchor any ladder);\n    weights mainly trade chop fee-capture "
              "vs tail robustness, same knee as at\n    inception "
              "(ladder_shape.py). FROZEN: k=1.3 @30% / k=2.0 @40% / full @30%.")


if __name__ == "__main__":
    main()
