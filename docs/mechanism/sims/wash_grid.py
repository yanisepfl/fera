#!/usr/bin/env python3
"""
wash_grid.py  --  wash-farming net-negativity proof (numeric grid).

A wash trader W round-trips volume V (quote units) through a MEME pool at
dynamic fee phi to farm emissions. Worst case for the protocol: W also owns
fraction f of the pool's vault shares (recaptures fees as an LP) AND is ~100%
of the pool's fee volume (captures ~all trader + LP emission share).

Emission budget is bounded:   E_usd <= beta * revenue_usd
where revenue = the 10% performance fee on collected LP fees = 0.10 * phi * V.
W captures  s_TR*E (trader, pro-rata fees paid) + f*s_LP*E (LP, pro-rata fees
earned); v2 split s_TR=0.10 / s_LP=0.80 (Decision-A'). esFERA is either vested
(full) or instant-exit (x0.5). No boost on either term here: Decision B removed
it from the trader leaf, and the pipeline ordering (SPEC 4.4) neutralizes it on
the LP leaf at f=1 (see lp_self_deal.py).

W's hard cost = fees paid minus fees recaptured as LP:
    cost = phi*V - f*(1-perf)*phi*V = phi*V*(1 - f*0.9)

Net (per $1 of wash volume, dropping the common phi*V factor), valued at the
FERA price ratio R = P_sell / P_emit:
    captured = (s_TR + f*s_LP)*beta*0.10 * (0.5 if instant else 1.0) * R
    cost     = (1 - 0.9*f)
    net      = captured - cost

Prints the grid and the FERA-appreciation break-even. Verdict.
"""
import argparse
import numpy as np

BETA = 0.80
PERF = 0.10
TRADER_SHARE = 0.10   # v2 (Decision-A'): was 0.45. Note: the f=1 worst case
LP_SHARE = 0.80       # depends only on s_TR+s_LP = 0.9, unchanged; every f<1
                      # cell is now MORE negative (trader leaf shrank 4.5x).
HAIRCUT_KEEP = 0.50   # instant exit keeps 50%


def net_per_wash_dollar(f, beta, exit_keep, R):
    captured = LP_SHARE * f * beta * PERF * exit_keep * R \
             + TRADER_SHARE * beta * PERF * exit_keep * R
    cost = 1.0 - 0.9 * f
    return captured - cost


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--beta", type=float, default=BETA)
    args = ap.parse_args()
    beta = args.beta
    print("=" * 70)
    print(f"FERA wash-farming net PnL grid   (beta={beta}, perf={PERF}, "
          f"haircut keeps {HAIRCUT_KEEP:.0%})")
    print("=" * 70)
    print("Net PnL per $1 of wash volume (negative = wash trader loses money).")
    print("Rows = LP ownership fraction f; columns = FERA price ratio R at exit.\n")

    f_grid = [0.0, 0.25, 0.5, 0.75, 1.0]
    R_grid = [0.5, 1.0, 1.5, 2.0, 3.0]

    for exit_keep, tag in [(HAIRCUT_KEEP, "INSTANT EXIT (50% haircut)"),
                           (1.0, "FULL 6-MONTH VEST (no haircut)")]:
        print(f"--- {tag} ---")
        header = "  f\\R   " + "".join(f"{R:>9.2f}" for R in R_grid)
        print(header)
        worst_pos = -1e9
        for f in f_grid:
            row = f"  {f:>4.2f}  "
            for R in R_grid:
                n = net_per_wash_dollar(f, beta, exit_keep, R)
                row += f"{n:>9.4f}"
            print(row)
        # break-even R at f=1 (best case for attacker)
        # captured(f=1) = (s_TR + s_LP)*beta*perf*keep*R = 0.9*beta*perf*keep*R
        # cost(f=1) = 0.1 ; break-even R = 0.1 / (0.9*beta*perf*keep)
        be_R = (1 - 0.9) / (0.9 * beta * PERF * exit_keep)
        print(f"  break-even FERA appreciation at f=1: R* = {be_R:6.2f}x "
              f"(W must believe FERA rises >{be_R:.2f}x and hold the risk)\n")

    # scan: is net<0 for ALL f at R<=1 (no appreciation)?
    all_neg = True
    for exit_keep in (HAIRCUT_KEEP, 1.0):
        for f in np.linspace(0, 1, 21):
            for R in (0.5, 1.0):
                if net_per_wash_dollar(f, beta, exit_keep, R) >= 0:
                    all_neg = False
    print("=" * 70)
    print(f"VERDICT: with no FERA appreciation (R<=1), wash-farming is "
          f"net-NEGATIVE for every ownership fraction and both exit modes: "
          f"{'PASS' if all_neg else 'FAIL'}")
    print("The only profitable path is an UNHEDGED 6-month FERA long that pays "
          "real perf-fee revenue to the protocol the whole time (R* break-even "
          "above); i.e. the 'attack' is buying FERA at a premium by subsidising "
          "stakers/treasury. Per-pool revenue cap makes this locally binding.")
    # guard: beta must stay below 1/(0.9) for R=1 full-vest negativity
    print(f"\nSafety margin: full-vest R=1 net at f=1 = "
          f"{net_per_wash_dollar(1.0, beta, 1.0, 1.0):+.4f}  "
          f"(stays <0 for all beta < {1/0.9:.3f}); frozen beta={beta}.")


if __name__ == "__main__":
    main()
