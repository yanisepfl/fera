#!/usr/bin/env python3
"""
D-M9 self-deal closure — independent numeric verification of MECHANISM_SPEC §4.2 / §4.7.
Security (Agent 6) co-sign gate. Reproduces the wash-farm net-EV grid from first principles
using the frozen constants (no reliance on the Mechanism sims).

Frozen constants (FeraConstants.sol / PARAMS v2):
  s_LP = 0.80, s_TR = 0.10, s_G = 0.10   (EMISSION_SPLIT)
  beta = 0.80                            (EMISSION_BETA; on-chain setter cap = 1.0 in code, 0.9 in spec)
  perf = 0.10                            (PERF_FEE_BPS)
  haircut keep: instant = 0.50, full vest = 1.00
"""

s_LP, s_TR, s_G = 0.80, 0.10, 0.10
beta = 0.80
perf = 0.10

def net_per_dollar(f, keep, Rp):
    """Net EV per $1 of wash quote-volume, dropping the common phi*V factor.
       captured = (s_TR + f*s_LP) * beta * perf * keep * Rp
       cost     = (1 - 0.9*f)      [pays phi*V, recaptures f*(1-perf)*phi*V as LP]"""
    captured = (s_TR + f*s_LP) * beta * perf * keep * Rp
    cost = (1 - (1-perf)*f)
    return captured - cost

def breakeven_Rp(f, keep):
    # net = 0  ->  Rp* = cost / [(s_TR+f*s_LP)*beta*perf*keep]
    denom = (s_TR + f*s_LP) * beta * perf * keep
    return (1 - (1-perf)*f) / denom

print("=== D-M9 verification ===")
print(f"split s_LP/s_TR/s_G = {s_LP}/{s_TR}/{s_G}, beta={beta}, perf={perf}\n")

# Clause 1: at Rp<=1 (flat/down FERA) net-negative for ALL f, both exits.
print("Clause 1 — net-negative at Rp<=1 for all f in [0,1]:")
worst = -1e9
for exit_name, keep in [("instant", 0.5), ("full-vest", 1.0)]:
    for i in range(0, 101):
        f = i/100
        n = net_per_dollar(f, keep, 1.0)
        worst = max(worst, n)
    n1 = net_per_dollar(1.0, keep, 1.0)
    print(f"   exit={exit_name:9s}: net@f=1,Rp=1 = {n1:+.4f}")
print(f"   MAX net over full f-grid, both exits, Rp=1 = {worst:+.4f}  -> {'NEGATIVE (PASS)' if worst<0 else 'POSITIVE (FAIL)'}\n")

# The spec's captured_max claim: (s_TR+s_LP)*beta*perf = 0.072 < cost_min(f=1)=0.10
cap_max = (s_TR+s_LP)*beta*perf
print(f"   captured_max (f=1,vest,Rp=1) = (s_TR+s_LP)*beta*perf = {cap_max:.4f}   (spec says 0.072)")
print(f"   cost_min (f=1)               = 1-0.9 = {1-0.9*1:.4f}")
print(f"   net_max                      = {cap_max-0.10:+.4f}   (spec says -0.028 = +2.8% to protocol)\n")

# General safety threshold: full-vest Rp=1 negative iff beta < 1/(s_TR+s_LP)
print(f"   safety: full-vest Rp=1 stays negative for beta < 1/(s_TR+s_LP) = {1/(s_TR+s_LP):.3f}")
print(f"           frozen beta=0.80 -> margin {(1/(s_TR+s_LP)-beta)/ (1/(s_TR+s_LP))*100:.1f}%")
print(f"           on-chain setter cap in CODE = 1.0 (EmissionsController.setBeta) -> at beta=1.0:")
n_b1 = (s_TR+s_LP)*1.0*perf - 0.10
print(f"           net_max@beta=1.0 = {n_b1:+.4f}  ({'still negative' if n_b1<0 else 'POSITIVE'})\n")

# Clause 2: break-even Rp (the "premium" the attacker pays vs spot).
print("Clause 2 — break-even FERA appreciation Rp* at f=1 (spec: instant 2.78x, vest 1.39x):")
print(f"   instant  Rp* = {breakeven_Rp(1.0,0.5):.2f}x   (spec 2.78x)")
print(f"   full-vest Rp* = {breakeven_Rp(1.0,1.0):.2f}x   (spec 1.39x)\n")

# Clause 3: spot-purchase dominance. Wash value per $cost vs buying FERA spot.
# buying FERA spot with $1 returns Rp of FERA value. Wash returns captured/cost * Rp-equivalent.
# ratio = captured_per_cost_dollar / 1  where captured_per_cost = X*keep/perf (X=(s_TR+s_LP)*beta*perf).
print("Clause 3 — spot dominance (wash FERA acquired per $ vs buying spot):")
X = (s_TR+s_LP)*beta*perf
for exit_name, keep in [("full-vest", 1.0), ("instant", 0.5)]:
    per_dollar = X*keep/perf
    prem = (1/per_dollar - 1)*100
    print(f"   exit={exit_name:9s}: wash acquires {per_dollar:.3f} FERA per $ that spot-buying 1.0 does"
          f"  -> +{prem:.0f}% premium ({'dominated' if per_dollar<1 else 'NOT dominated'})")
print()

# The UNMET cell: exclusion-evaded + strong appreciation. cost/profit ratio vs the 10x bar.
# profit-per-$ = net(f=1,keep,Rp); cost-per-$ = cost = 0.10. ratio = cost/profit? Spec frames
# cost/profit as (fees paid)/(net emission profit). Reproduce the reported cells.
print("Clause 4 — the UNMET 10x-bar cell (exclusion evaded + FERA appreciates), f=1:")
for Rp in [2, 3, 4]:
    for exit_name, keep in [("instant",0.5),("full-vest",1.0)]:
        n = net_per_dollar(1.0, keep, Rp)
        if n > 0:
            ratio = 0.10 / n  # fee-cost per unit net profit
            print(f"   Rp={Rp}x {exit_name:9s}: net=+{n:.3f}/$  cost/profit={ratio:.2f}x  "
                  f"{'>=10x (PASS bar)' if ratio>=10 else '< 10x (BAR NOT MET)'}")
        else:
            print(f"   Rp={Rp}x {exit_name:9s}: net={n:+.3f}/$  (unprofitable — no attack)")
