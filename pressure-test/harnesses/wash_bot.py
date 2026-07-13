#!/usr/bin/env python3
"""
wash_bot.py  —  FERA Pressure-Test harness for M4 (token attacks).

QUESTION:
    Is wash-farming the emission rebate net-NEGATIVE, given the emission bound
    (emitted <= beta * revenue) and the esFERA instant-exit haircut? And what
    is the cheapest PROFITABLE variant, if one exists?

CORE ARITHMETIC (the "net-negative by construction" claim):
    A self-dealing whale that both TRADES and LPs its own pool generates fee
    volume F. Of F, the protocol skims the 10% perf fee (its revenue R = 0.10 F)
    and returns 0.90 F to LPs (the whale). So the whale's UNAVOIDABLE cost of
    washing is the perf fee = 0.10 F (+ gas ~0 under the gas holiday + external
    arb leakage lambda*F).

    Max emission the whale can recapture:
        E   <= beta * R            = beta * 0.10 * F          (revenue bound)
        take = (TRADER_SPLIT + LP_SPLIT) * boost_share * E    (both rebates)
    With boost=1 and full self-capture (share=1):
        take = 0.90 * 0.80 * 0.10 * F = 0.072 F               (valued in FERA)

    reward/cost = 0.072 / 0.10 = 0.72  ->  net-negative WITHOUT boost, but the
    margin is only 28% at full vest with FLAT FERA price. The break-even FERA
    appreciation over the vest is g* = 0.10/0.072 = 1.39x. With a 2x self-boost
    the whale over-collects honest users' emission share and turns PROFITABLE.

WHAT IT DOES:
    Grids over (FERA appreciation g, boost b, self-LP ownership s, exit mode,
    whale fee-share theta of the protocol-wide base) and prints, for each cell,
    reward/cost and the cost/profit ratio, with PASS/FAIL.

VERDICT RULE (from the mission): cost/profit >= 10x => PASS (attack costs >=10x
    what it yields). Anything < 10x => FAIL (attack is cheap relative to reward).
    For a net-negative attack "profit" is negative -> reported as PASS (inf).

DATA: closed-form / synthetic. Structured to accept real fee + boost-state data
    later (feed measured F, R, boost distribution). Says so.
PARAMS: structural defaults from params.py (PARAMS.md pending).
"""
import argparse
import sys
import numpy as np

import params as P


def whale_take_fraction(theta, boost, cross_boosted_frac=1.0):
    """Fraction of the epoch emission E the whale captures across BOTH rebates,
    when it is `theta` of the protocol-wide fee base with multiplier `boost`,
    everyone else unboosted (multiplier 1). Emission is a FIXED pool (<= beta*R)
    that boost REALLOCATES (INV-7): boosted weight / total weight.

    share_of_a_split = boost*theta / (boost*theta + (1-theta))
    Whale is both the paying trader and the earning LP for its own flow, so it
    claims that share of BOTH the 45% trader split and the 45% LP split.
    """
    denom = boost * theta + (1.0 - theta)
    split_share = (boost * theta) / denom if denom > 0 else 0.0
    return (P.TRADER_SPLIT + P.LP_SPLIT) * split_share


def evaluate(theta, boost, self_lp, g, instant_exit, arb_leak=0.0):
    """
    Returns dict with reward/cost economics per unit of TOTAL protocol fee base F=1.
    theta       : whale's share of protocol-wide fee base (its washed fees = theta*F)
    boost       : whale emission multiplier in [1, MAX_BOOST]
    self_lp     : fraction of its own pool the whale owns (recovers 0.90 of its fees * self_lp)
    g           : FERA price multiple over the vest (1.0 = flat)
    instant_exit: True -> 50% haircut, no appreciation; False -> full vest, gets g
    arb_leak    : external arb leakage as fraction of washed fees
    """
    F = 1.0
    washed_fees = theta * F
    # Cost: perf fee on washed fees that the whale does NOT recover as its own LP.
    # It recovers 0.90 * self_lp of its washed fees; loses the rest + perf fee.
    recovered = 0.90 * self_lp * washed_fees
    unavoidable_perf = P.PERF_FEE * washed_fees           # protocol skim
    not_recovered_lp = (0.90 * washed_fees) - recovered   # LP fees leaked to other LPs
    cost = unavoidable_perf + not_recovered_lp + arb_leak * washed_fees

    # Emission pool (revenue bound binds = attacker best case; cap only lowers it)
    R = P.PERF_FEE * F                                     # protocol revenue this epoch
    E = P.BETA * R                                         # <= min(cap, beta*R)
    take_frac = whale_take_fraction(theta, boost)
    take_fera = take_frac * E                              # esFERA face value (USD)

    if instant_exit:
        reward = take_fera * (1.0 - P.INSTANT_EXIT_HAIRCUT)   # 50% haircut, now
    else:
        reward = take_fera * g                                # full vest, price g

    net = reward - cost
    ratio_reward_cost = reward / cost if cost > 0 else np.inf
    cost_over_profit = (cost / net) if net > 0 else np.inf    # net<=0 -> attack fails -> inf
    return {
        "theta": theta, "boost": boost, "self_lp": self_lp, "g": g,
        "instant": instant_exit, "cost": cost, "reward": reward, "net": net,
        "reward/cost": ratio_reward_cost, "cost/profit": cost_over_profit,
        "profitable": net > 0,
    }


def verdict(cost_over_profit, threshold=10.0):
    return "PASS" if cost_over_profit >= threshold else "FAIL"


def main():
    ap = argparse.ArgumentParser(description="FERA M4 wash-farming break-even")
    ap.add_argument("--threshold", type=float, default=10.0,
                    help="cost/profit >= threshold => PASS")
    args = ap.parse_args()

    print("=" * 74)
    print("FERA M4 WASH-FARMING BREAK-EVEN  (beta-bound + 50% haircut)")
    print(f"consts: perf={P.PERF_FEE:.0%}  beta={P.BETA}  splits(tr/lp)="
          f"{P.TRADER_SPLIT}/{P.LP_SPLIT}  haircut={P.INSTANT_EXIT_HAIRCUT:.0%}  "
          f"maxboost={P.MAX_BOOST}")
    print("DATA: closed-form (no real fee/boost data wired). PARAMS.md pending.")
    print("Rule: cost/profit >= 10x => PASS ; net<=0 => attack fails => PASS(inf)")
    print("=" * 74)

    # ---- Case A: base claim — self-dealing whole-pool whale, NO boost --------
    print("\n[A] Self-dealing whole-pool whale, boost=1, owns 100% of its pool")
    for instant, g, label in [(True, 1.0, "instant-exit (50% haircut)"),
                              (False, 1.0, "full vest, FERA flat (g=1.0)"),
                              (False, 1.39, "full vest, FERA +39% (g=1.39)"),
                              (False, 2.0, "full vest, FERA +100% (g=2.0)")]:
        r = evaluate(theta=1.0, boost=1.0, self_lp=1.0, g=g, instant_exit=instant)
        v = verdict(r["cost/profit"], args.threshold)
        print(f"  {label:32s}  reward/cost={r['reward/cost']:.2f}  "
              f"net={r['net']:+.4f}F  cost/profit={fmt(r['cost/profit'])}  -> {v}")
    print("  -> break-even FERA appreciation over vest = 0.10/0.072 = 1.39x")

    # ---- Case B: 2x SELF-BOOST redistribution attack ------------------------
    print("\n[B] 2x self-boost, whale is a MINORITY theta of protocol-wide fees")
    print("    (boost reallocates a fixed pool -> whale steals honest users' share)")
    for theta in [0.50, 0.20, 0.05, 0.01]:
        r = evaluate(theta=theta, boost=P.MAX_BOOST, self_lp=1.0, g=1.0,
                     instant_exit=False)
        v = verdict(r["cost/profit"], args.threshold)
        print(f"  theta={theta:>5.2f}  reward/cost={r['reward/cost']:.2f}  "
              f"net={r['net']:+.5f}F  cost/profit={fmt(r['cost/profit'])}  "
              f"profit={'YES' if r['profitable'] else 'no'}  -> {v}")
    print("    break-even FERA appreciation WITH 2x boost = 0.10/0.144 = 0.69x")
    print("    (i.e. profitable even if FERA FALLS up to 31% over the vest)")

    # ---- Case C: sweep boost x appreciation (worst realistic cell) ----------
    print("\n[C] Worst-cell sweep: does ANY realistic config give cost/profit<10x?")
    worst = None
    for theta in [0.01, 0.05, 0.2, 0.5, 1.0]:
        for boost in [1.0, 1.5, 2.0]:
            for g in [0.7, 1.0, 1.39, 2.0]:
                r = evaluate(theta=theta, boost=boost, self_lp=1.0, g=g,
                             instant_exit=False)
                if r["profitable"]:
                    if worst is None or r["cost/profit"] < worst["cost/profit"]:
                        worst = r
    if worst is None:
        print("  no profitable config found in the grid -> base defense holds")
        overall = "PASS"
    else:
        print(f"  CHEAPEST PROFITABLE ATTACK: theta={worst['theta']}, "
              f"boost={worst['boost']}, g={worst['g']}")
        print(f"    reward/cost={worst['reward/cost']:.2f}  net={worst['net']:+.5f}F  "
              f"cost/profit={worst['cost/profit']:.2f}x")
        overall = verdict(worst["cost/profit"], args.threshold)

    print("\n" + "=" * 74)
    print(f"OVERALL M4 WASH VERDICT: {overall}")
    if overall == "FAIL":
        print("  Base (no-boost) claim holds net-negative at flat FERA, but the")
        print("  margin is only 28% and BREAKS under: (i) 2x self-boost, or")
        print("  (ii) FERA appreciation > 39% over the vest. Boost must not apply")
        print("  to self-generated/self-LP'd flow. See memo 04.")
    print("=" * 74)


def fmt(x):
    return "inf" if np.isinf(x) else f"{x:.2f}x"


if __name__ == "__main__":
    sys.exit(main())
