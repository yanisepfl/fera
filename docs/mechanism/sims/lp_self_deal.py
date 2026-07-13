#!/usr/bin/env python3
"""
lp_self_deal.py  --  INV-13 residual: the LP-side self-deal, and the frozen fix.

The residual attack after Decision B (boost on LP emissions only): a whale
deposits into the Core tranche, wash-trades his own pool (open liquidity D-11
makes the trading leg trivially easy), and collects boosted (<=2x) LP emissions
on the fees he paid himself.

Per $1 of wash fee paid at dynamic fee phi (all quantities per fee-dollar;
the common phi*V factor drops out):

  hard cost      = 1 - 0.9*f*psi          (recaptures 90% of fees via his
                                           tranche-share fraction f; psi = the
                                           vault's in-range fee share vs direct
                                           LPs -- psi<1 makes the attack STRICTLY
                                           worse, so psi=1 is the worst case)
  capture        = [ s_TR * traderLeaf + LPboostFactor * s_LP ] * beta * perf
                     * keep * Rp
      traderLeaf : 1 (he is ~all of his pool's fee-payers). NO boost (Decision B).
      LPboostFactor depends on the pipeline design:
        'global' (PRE-FIX, PT-2 model): boost reweights the GLOBAL LP pool; a
                 small attacker (theta->0) with max boost takes 2x his pro-rata
                 => factor = 2*f       -- steals honest pools' emissions.
        'pool'  (POST-FIX): the per-pool revenue lock is applied AFTER boost
                 (PT-5) and the split is applied WITHIN the pool, so boost can
                 only redistribute among the SAME pool's LPs:
                 factor = min(1, 2f/(1+f))  -- at f=1 boost self-cancels.
        'none'  : factor = f (no boost).
      keep: 0.5 instant exit / 1.0 full 6-mo vest.  Rp = P_exit / P_emit.
  exclusion      : if the self-match cluster heuristic links the trader wallets
                   to the share-holder cluster, BOTH leaves are excluded -> 0.

Also prints:
  - the spot-purchase dominance test (is wash-farming ever a better way to
    acquire FERA than just buying it?),
  - ATTACK 2 (PT-8): FERA-TWAP suppression cost/gain for one epoch under the
    frozen window + clamps.

Closed-form, deterministic. Verdict printed. Honest about what is NOT met.
"""
import argparse

PERF = 0.10
BETA = 0.80
BAR = 10.0          # pressure-test bar: cost/profit >= 10x

SPLITS = {
    "old 45/45/10": (0.45, 0.45),
    "NEW 80/10/10": (0.10, 0.80),
}


def capture(s_tr, s_lp, f, mode, boost_both_sides=False):
    if mode == "global":
        lp_factor = 2.0 * f
        tr_factor = 2.0 if boost_both_sides else 1.0
    elif mode == "pool":
        lp_factor = min(1.0, 2.0 * f / (1.0 + f)) if f > 0 else 0.0
        tr_factor = 1.0
    elif mode == "none":
        lp_factor = f
        tr_factor = 1.0
    else:
        raise ValueError(mode)
    return (s_tr * tr_factor + s_lp * lp_factor) * BETA * PERF


def net(s_tr, s_lp, f, mode, keep, Rp, psi=1.0, excluded=False,
        boost_both_sides=False):
    cost = 1.0 - 0.9 * f * psi
    cap = 0.0 if excluded else capture(s_tr, s_lp, f, mode,
                                       boost_both_sides) * keep * Rp
    return cap - cost, cost, cap


def cost_profit(s_tr, s_lp, f, mode, keep, Rp):
    n, cost, _ = net(s_tr, s_lp, f, mode, keep, Rp)
    if n <= 0:
        return float("inf")
    return cost / n


def main():
    argparse.ArgumentParser().parse_args()
    print("=" * 76)
    print("FERA LP-side self-deal (INV-13 residual)  --  attack grid + frozen fix")
    print(f"(beta={BETA}, perf={PERF}; per $1 of wash FEE paid; psi=1 worst case)")
    print("=" * 76)

    # ---- 1. PT-2 reproduction + Decision B alone ----
    print("\n[1] Why split/boost tweaks alone do NOT fix it "
          "(theta->0 attacker, f=1, full vest, Rp=1):")
    print(f"  {'design':<58}{'capture':>9}{'cost':>7}{'net':>9}")
    rows = [
        ("PRE-FIX  45/45/10, boost BOTH leaves, global pool (PT-2 M4)",
         ("old 45/45/10", "global", True)),
        ("Decision B only: 45/45/10, boost LP leaf, global pool",
         ("old 45/45/10", "global", False)),
        ("Decision B only: 80/10/10, boost LP leaf, global pool",
         ("NEW 80/10/10", "global", False)),
    ]
    for label, (split, mode, both) in rows:
        s_tr, s_lp = SPLITS[split]
        n, cost, cap = net(s_tr, s_lp, 1.0, mode, 1.0, 1.0,
                           boost_both_sides=both)
        print(f"  {label:<58}{cap:>9.4f}{cost:>7.2f}{n:>+9.4f}"
              f"{'  PROFITABLE' if n > 0 else ''}")
    print("  -> LP-dominant splits make the GLOBAL-boost leak WORSE (2x on a")
    print("     bigger LP pool: 0.136 > 0.108). The fix must be structural.")

    # ---- 2. The ordering fix ----
    print("\n[2] STRUCTURAL FIX (frozen, MECHANISM_SPEC 4.4/4.5): the per-pool")
    print("    revenue lock is enforced AFTER boost weighting and the split is")
    print("    applied WITHIN each pool -> boost can never import emissions from")
    print("    other pools; at f=1 boost redistributes among the attacker alone.")
    s_tr, s_lp = SPLITS["NEW 80/10/10"]
    print(f"\n    net per fee-dollar, NEW split, post-fix, sweep f "
          f"(full vest, Rp=1):")
    print("      f    : " + "".join(f"{f:>9.2f}" for f in
                                    (0.0, 0.25, 0.5, 0.75, 0.9, 1.0)))
    print("      net  : " + "".join(
        f"{net(s_tr, s_lp, f, 'pool', 1.0, 1.0)[0]:>+9.4f}"
        for f in (0.0, 0.25, 0.5, 0.75, 0.9, 1.0)))
    print("    -> maximum at f=1 (as before); boost neutralized.")

    # ---- 3. price-path grid at the post-fix optimum (f=1) ----
    print("\n[3] Post-fix attack grid at f=1, across FERA price paths "
          "(Rp = P_exit/P_emit):")
    Rps = (0.25, 0.5, 1.0, 1.39, 2.0, 3.0, 4.0)
    for split in ("NEW 80/10/10", "old 45/45/10"):
        s_tr, s_lp = SPLITS[split]
        print(f"\n  split {split}   (capture coeff X = (s_TR+s_LP)*beta*perf = "
              f"{(s_tr+s_lp)*BETA*PERF:.4f}, cost 0.10)")
        for keep, tag in ((0.5, "instant exit"), (1.0, "full 6-mo vest")):
            nets = [net(s_tr, s_lp, 1.0, 'pool', keep, R)[0] for R in Rps]
            cps = [cost_profit(s_tr, s_lp, 1.0, 'pool', keep, R) for R in Rps]
            be = 0.10 / ((s_tr + s_lp) * BETA * PERF * keep)
            print(f"    {tag:<16} net : " +
                  "".join(f"{n:>+9.4f}" for n in nets))
            print(f"    {'':<16} c/p : " +
                  "".join(f"{'inf' if c == float('inf') else f'{c:.2f}x':>9}"
                          for c in cps) + f"   break-even Rp*={be:.2f}x")
    print("    (columns: Rp = " + ", ".join(str(R) for R in Rps) + ")")

    # ---- 4. self-match exclusion ----
    print("\n[4] SELF-MATCH EXCLUSION (frozen, MECHANISM_SPEC 4.7): when the")
    print("    funding-cluster heuristic links the trader wallets to the share-")
    print("    holder cluster, both leaves are excluded from emission weights:")
    n, cost, _ = net(0.10, 0.80, 1.0, 'pool', 1.0, 4.0, excluded=True)
    print(f"      detected : capture=0, net={n:+.4f} at Rp=4 -> cost/profit = inf "
          f"(PASS, any Rp)")
    print("      evaded   : (fresh CEX-funded wallets + router-mediated swaps ->")
    print("                 trader field = solver/router, unclusterable) -> falls")
    print("                 back to [3]. Exclusion is friction, not a bound.")

    # ---- 5. dominance ----
    print("\n[5] SPOT-PURCHASE DOMINANCE (the economic bound that holds for ALL Rp):")
    print("    same budget C: wash-farm yields X*keep*Rp/0.10 of FERA value;")
    print("    buying FERA spot yields C*Rp. Wash beats spot iff X*keep > cost:")
    for split in ("NEW 80/10/10", "old 45/45/10"):
        s_tr, s_lp = SPLITS[split]
        X = (s_tr + s_lp) * BETA * PERF
        for keep, tag in ((1.0, "full vest"), (0.5, "instant")):
            print(f"      {split}, {tag:<10}: X*keep/cost = "
                  f"{X*keep/0.10:.2f} < 1  -> wash-farming acquires FERA at a "
                  f"{0.10/(X*keep)-1:+.0%} premium vs market")
    print("    -> for EVERY price path, a rational actor who wants FERA upside")
    print("       buys spot; wash-farming is strictly dominated. The attack has")
    print("       no rational operator; an irrational one pays the protocol.")

    # ---- 6. honest verdict ----
    print("\n" + "=" * 76)
    worst_cp = cost_profit(0.10, 0.80, 1.0, 'pool', 1.0, 4.0)
    cp2 = cost_profit(0.10, 0.80, 1.0, 'pool', 1.0, 2.0)
    print("VERDICT (honest):")
    print(f"  - Rp<=1 (flat/down FERA): net-negative for every f, both exits. PASS.")
    print(f"  - boost leak (PT-2): ELIMINATED by pipeline ordering; Decision B +")
    print(f"    ordering make capture identical to the no-boost case (X=0.072).")
    print(f"  - absolute 10x bar: NOT met on appreciation paths if exclusion is")
    print(f"    evaded: cost/profit = {cp2:.2f}x at Rp=2, {worst_cp:.2f}x at Rp=4 "
          f"(bar {BAR:.0f}x).")
    print(f"  - the defensible bound is [5]: wash-farming is strictly dominated by")
    print(f"    spot purchase at ALL Rp (attacker pays a 39% premium, full vest),")
    print(f"    honest users lose NOTHING (his emissions are funded by his own")
    print(f"    perf fee under the per-pool lock; stakers/treasury net +2.8% of")
    print(f"    his wash fees), and the 10x bar IS met whenever the cluster")
    print(f"    heuristic catches the self-deal (capture=0).")
    print(f"  - residual risk owner: Security co-sign requested "
          f"(OPEN_DECISIONS.md#D-M9).")

    # ---- 7. ATTACK 2: FERA TWAP suppression (PT-8) ----
    print("\n" + "=" * 76)
    print("ATTACK 2 (PT-8): FERA-TWAP suppression during the epoch snapshot")
    print("=" * 76)
    print("  Frozen: 7d geometric TWAP; per-observation clamp +/-200bps/block;")
    print("  epoch-over-epoch valuation drop clamp 30%; min cardinality 5000 obs")
    print("  (else fail-static to previous epoch TWAP). Clamps only ever UNDER-")
    print("  emit (safe direction).")
    print("\n  gain(delta) = E_usd * delta/(1-delta) (attacker holds the extra")
    print("  FERA through recovery); cost(delta) ~= delta * A * 7d where A = daily")
    print("  net arb absorption against a peg deviation (attacker sells into the")
    print("  arb bid at a delta discount for the whole window).")
    E = 14_300.0   # steady-state weekly emission value = beta * weekly revenue
                   # (split_optimizer base: rev ~ $927k/yr -> $17.8k/wk * 0.8)
    print(f"\n  base-case weekly emission value E = ${E:,.0f} "
          f"(split_optimizer steady state)")
    print(f"  {'delta':>7} {'gain($)':>10}" +
          "".join(f"{'cost@A=$'+f'{A/1000:.0f}k/d':>16}" for A in (10e3, 30e3, 100e3)) +
          f"{'cost/gain @A=30k':>18}")
    for delta in (0.05, 0.15, 0.30):
        gain = E * delta / (1 - delta)
        costs = [delta * A * 7 for A in (10e3, 30e3, 100e3)]
        print(f"  {delta:>7.0%} {gain:>10,.0f}" +
              "".join(f"{c:>16,.0f}" for c in costs) +
              f"{costs[1]/gain:>17.1f}x")
    print("\n  cost/gain = 7*A*(1-delta)/E, independent of delta to first order.")
    print(f"  10x bar holds iff A >= ~1.5x weekly emission value "
          f"(A >= ${1.5*E:,.0f}/day here).")
    print("  Both sides are observable (E on the transparency endpoint; FERA pool")
    print("  volume on-chain) -> published as a MONITORED CONDITION; the 30% epoch")
    print("  drop-clamp bounds the worst single-epoch over-emission to 43% of E")
    print("  even if suppression is sustained and free.")
    print("  VERDICT: PASS under the monitored condition; clamp bounds the tail.")


if __name__ == "__main__":
    main()
