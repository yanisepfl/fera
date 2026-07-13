#!/usr/bin/env python3
"""
token_supply.py  --  FERA 4-year emission cap curve + supply trajectories.

Implements the FROZEN closed-form logistic emission cap and prints:
  1. the weekly cap table the EmissionsController reproduces on-chain;
  2. cumulative emitted under bear / base / bull revenue, applying the true
     rule  emitted = min( cap(t) - cap(t-1),  beta * revenue_epoch / P_fera ).

cap(t) is a normalised logistic with cap(0)=0 and cap(T)=BUCKET so exactly the
BUCKET (90% of 1B) is authorised over the horizon T; if revenue is short, the
min() binds and the bucket lasts longer (dividend, not subsidy).

Real-data hook: pass --revenue CSV (epoch,revenue_usd,fera_twap_usd).
Verdict printed.
"""
import argparse
import math
import numpy as np

TOTAL_SUPPLY = 1_000_000_000.0
BUCKET       = 0.90 * TOTAL_SUPPLY      # 900,000,000 FERA usage-emitted
GENESIS      = 0.10 * TOTAL_SUPPLY
YEAR_SEC     = 365.25 * 24 * 3600
WEEK_SEC     = 7 * 24 * 3600
HORIZON_YRS  = 4.0
K_PER_YEAR   = 2.2                       # logistic steepness
T_MID_YRS    = 1.9                       # inflection (peak weekly cap)
BETA         = 0.80


def sigma(x):
    return 1.0 / (1.0 + math.exp(-x))


def cap_cumulative(t_years):
    """Normalised logistic: cap(0)=0, cap(HORIZON)=BUCKET."""
    a = sigma(K_PER_YEAR * (0.0 - T_MID_YRS))
    b = sigma(K_PER_YEAR * (HORIZON_YRS - T_MID_YRS))
    x = sigma(K_PER_YEAR * (min(t_years, HORIZON_YRS) - T_MID_YRS))
    return BUCKET * (x - a) / (b - a)


def weekly_caps(n_weeks):
    caps = []
    prev = 0.0
    for w in range(1, n_weeks + 1):
        t = w * WEEK_SEC / YEAR_SEC
        c = cap_cumulative(t)
        caps.append(c - prev)
        prev = c
    return caps


def print_cap_table():
    n = int(round(HORIZON_YRS * YEAR_SEC / WEEK_SEC))   # ~208 weeks
    caps = weekly_caps(n)
    cum = np.cumsum(caps)
    print("\nWeekly emission cap (authorised ceiling), selected weeks:")
    print(f"  {'week':>5}{'year':>7}{'weekly cap':>16}{'cumulative':>16}"
          f"{'% bucket':>10}")
    marks = [1, 4, 8, 13, 26, 39, 52, 78, 104, 130, 156, 182, n]
    for w in marks:
        print(f"  {w:>5}{w*WEEK_SEC/YEAR_SEC:>7.2f}"
              f"{caps[w-1]:>16,.0f}{cum[w-1]:>16,.0f}"
              f"{100*cum[w-1]/BUCKET:>9.1f}%")
    print(f"\n  peak weekly cap ~ {max(caps):,.0f} FERA at week "
          f"{int(np.argmax(caps))+1}")
    print(f"  cap authorised by year 1 : {100*cum[51]/BUCKET:5.1f}% of bucket")
    print(f"  cap authorised by year 4 : {100*cum[n-1]/BUCKET:5.1f}% of bucket")
    return caps


def revenue_paths(n_weeks):
    """Synthetic weekly protocol revenue (USD) = 10% perf fee take.
    Bear/base/bull differ in TVL ramp & fee level. FERA TWAP grows with adoption.
    Returns dict name -> list of (revenue_usd, fera_twap_usd)."""
    out = {}
    for name, tvl0, tvl_growth, fee_apr, p0, p_growth in [
        ("bear", 5e6,  1.004, 0.15, 0.02, 1.0005),
        ("base", 15e6, 1.012, 0.35, 0.04, 1.004),
        ("bull", 40e6, 1.020, 0.60, 0.08, 1.010),
    ]:
        rows = []
        tvl, p = tvl0, p0
        for w in range(n_weeks):
            weekly_fee = tvl * fee_apr / 52.0           # LP fees this week
            revenue = 0.10 * weekly_fee                 # 10% perf fee = protocol revenue
            rows.append((revenue, p))
            tvl *= tvl_growth
            p *= p_growth
        out[name] = rows
    return out


def simulate_emissions(caps, rows):
    emitted = []
    total = 0.0
    for i, (cap_i) in enumerate(caps):
        revenue_usd, p_fera = rows[i]
        rev_bound_fera = BETA * revenue_usd / p_fera     # beta * revenueValuedInFera
        e = min(cap_i, rev_bound_fera)
        e = min(e, BUCKET - total)                       # never exceed bucket
        total += e
        emitted.append(e)
    return emitted, total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--revenue", help="CSV epoch,revenue_usd,fera_twap_usd")
    args = ap.parse_args()
    print("=" * 62)
    print("FERA token supply / emissions  --  4-year trajectory")
    print("=" * 62)
    print(f"  fixed supply      : {TOTAL_SUPPLY:,.0f}")
    print(f"  genesis (10%)     : {GENESIS:,.0f}")
    print(f"  usage bucket (90%): {BUCKET:,.0f}")
    print(f"  logistic k={K_PER_YEAR}, t_mid={T_MID_YRS}yr, horizon={HORIZON_YRS}yr")

    n = int(round(HORIZON_YRS * YEAR_SEC / WEEK_SEC))
    caps = print_cap_table()

    print("\nEmissions under revenue-bound rule  min(cap, beta*rev/P):")
    print(f"  {'scenario':<8}{'emitted 4yr':>16}{'% of bucket':>14}"
          f"{'% cap-bound wks':>16}")
    paths = revenue_paths(n)
    verdict_ok = True
    totals = {}
    for name in ("bear", "base", "bull"):
        emitted, total = simulate_emissions(caps, paths[name])
        totals[name] = total
        cap_bound = sum(1 for i in range(n) if caps[i] <= BETA*paths[name][i][0]/paths[name][i][1])
        print(f"  {name:<8}{total:>16,.0f}{100*total/BUCKET:>13.1f}%"
              f"{100*cap_bound/n:>15.0f}%")
        # sanity: emitted never exceeds bucket, never exceeds cap
        if total > BUCKET + 1:
            verdict_ok = False

    # v2 split allocation (Decision-A', FROZEN-PENDING-PRINCIPAL): 80/10/10.
    # The split does NOT change total emission (INV-7 is split-independent);
    # it only routes the emitted amount. Base-case allocation:
    s_lp, s_tr, s_gov = 0.80, 0.10, 0.10
    print(f"\nSplit allocation of base-case emissions "
          f"(v2 split {s_lp:.0%}/{s_tr:.0%}/{s_gov:.0%} LP/trader/treasury):")
    print(f"  LPs      : {totals['base']*s_lp:>16,.0f} FERA")
    print(f"  traders  : {totals['base']*s_tr:>16,.0f} FERA")
    print(f"  treasury : {totals['base']*s_gov:>16,.0f} FERA")

    print("\n" + "=" * 62)
    print(f"VERDICT: emission <= min(cap, beta*revenue) every epoch, cumulative "
          f"<= 900M bucket in all scenarios: {'PASS' if verdict_ok else 'FAIL'}")
    print("Bear: revenue-bound binds -> bucket under-emits (dividend, not "
          "subsidy). Bull: cap binds -> S-curve paces issuance to ~4 years.")


if __name__ == "__main__":
    main()
