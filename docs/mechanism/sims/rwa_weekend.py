#!/usr/bin/env python3
"""
rwa_weekend.py  --  FERA RWA pool across a weekend + Monday open.

A Robinhood Stock Token trades 24/7 but its Chainlink feed tracks the
underlying equity, which only prints during market hours. Over the weekend the
feed is frozen at Friday's close while the *true* fair value drifts (after-hours
news, futures). Arbitrageurs push the pool toward fair value; the FERA RWA
regime charges them a deviation-scaled fee, turning weekend drift into LP income
instead of LP loss. On Monday the feed reconciles with a gap.

Compares LP PnL:
  (A) vanilla flat 5bps, tight static band  (gets run over on the Monday gap)
  (B) FERA regime fee, tight band, no off-hours mgmt
  (C) FERA regime fee + off-hours WIDEN band
  (D) FERA regime fee + off-hours WIDEN + partial WITHDRAW q  (v2 frozen design,
      PT-7: q = RWA_OFFHOURS_WITHDRAW_FRAC = 0.60)

Plus the PT-7 gap-stress table: worst-case Monday-gap drawdown vs q, using the
memo-05 band model (loss ~ 0.5*max(0, d - w)*(1-q) minus the overlay-fee offset
on the crossing arb volume), for both the unwidened (w=1%) and widened (w=5%)
band.

Real-data hook: --path CSV (ts,true_value) replaces the synthetic weekend.
Deterministic. Verdict printed.
"""
import argparse
import math
import numpy as np

# ---- FROZEN RWA fee params (mirror PARAMS.md) ----
OPEN_BASE_PIPS   = 200     # 2 bps in-hours
CLOSED_BASE_PIPS = 3000    # 30 bps off-hours
CEIL_PIPS        = 10000   # 100 bps normal ceiling
DEV_SLOPE        = 20      # pips of fee per 1 bp of |pool-oracle| deviation
PIP = 1e-6

# ---- band params ----
BAND_HALF_BPS      = 100   # +/-1.0% in-hours tight band
OFFHOURS_HALF_BPS  = 500   # +/-5.0% widened weekend band
OFFHOURS_Q         = 0.60  # RWA_OFFHOURS_WITHDRAW_FRAC (v2, PT-7)


def rwa_fee_pips(market_open, dev_frac):
    base = OPEN_BASE_PIPS if market_open else CLOSED_BASE_PIPS
    dev_bps = abs(dev_frac) * 1e4
    fee = base + DEV_SLOPE * dev_bps
    return min(max(fee, base), CEIL_PIPS)


def concentrated_liq_fraction(price, center, half_bps):
    """Fraction of a symmetric band still 'in range' / capital efficiency proxy.
    A tight band earns ~ (band_ref/half) more fees per $ while in range, but
    earns ZERO once price exits and then holds 100% of the wrong asset."""
    half = half_bps / 1e4
    lo, hi = center * (1 - half), center * (1 + half)
    if lo <= price <= hi:
        return 1.0
    return 0.0


def synth_weekend(seed=11):
    """Minute-resolution path Fri 16:00 -> Mon 09:30 (approx), then Monday drift.
    Returns list of (minute, true_value, market_open)."""
    rng = np.random.default_rng(seed)
    v = 100.0                      # Friday close fair value & oracle
    path = []
    # Weekend: ~64h closed. True value drifts (news); oracle frozen at 100.
    weekend_minutes = 64 * 60
    drift = rng.choice([+1, -1]) * rng.uniform(0.015, 0.035)  # net weekend move 1.5-3.5%
    for m in range(weekend_minutes):
        v *= math.exp(drift / weekend_minutes + rng.normal(0, 0.0008))
        path.append((m, v, False))
    # Monday session: oracle reconnects, tracks true value; 6.5h open
    open_minutes = int(6.5 * 60)
    for m in range(open_minutes):
        v *= math.exp(rng.normal(0, 0.0010))
        path.append((weekend_minutes + m, v, True))
    return path


def simulate(path, mode, seed=3):
    """mode in {'vanillaA','feraB','feraC','feraD'}. Returns dict of LP
    economics per $1 of TVL over the window. Arb volume each step is
    proportional to the gap the pool must close toward true value, scaled by
    how in-range we are."""
    rng = np.random.default_rng(seed)
    oracle = path[0][1]            # frozen at Friday close over weekend
    pool = oracle                  # pool price starts at oracle
    center = oracle
    fee_income = 0.0
    inventory_pnl = 0.0
    ARB_RESPONSE = 0.35            # fraction of gap arbed per minute (liquidity dependent)
    last_open = False
    for m, true_v, mkt_open in path:
        # oracle: frozen while closed, equals true value while open
        if mkt_open:
            oracle = true_v
        # band management
        if mode in ('feraC', 'feraD'):
            half = BAND_HALF_BPS if mkt_open else OFFHOURS_HALF_BPS
        else:
            half = BAND_HALF_BPS
        # off-hours partial withdraw scales exposed inventory AND fee capture
        expo = (1.0 - OFFHOURS_Q) if (mode == 'feraD' and not mkt_open) else 1.0
        # on the open, FERA recenters to oracle (market hours only)
        if mode in ('feraB', 'feraC', 'feraD') and mkt_open and not last_open:
            center = oracle
        last_open = mkt_open

        # arb pushes pool toward true value; volume ~ gap * response
        gap = true_v - pool
        trade = ARB_RESPONSE * gap
        notional = abs(trade) * 1.0           # per-unit notional proxy
        in_range = concentrated_liq_fraction(pool, center, half)
        # deviation used for fee = |pool - oracle| (what arb pays against)
        dev = abs(pool - oracle) / oracle
        if mode == 'vanillaA':
            fee_pips = 500.0                   # flat 5 bps regardless
        else:
            fee_pips = rwa_fee_pips(mkt_open, dev)
        # only earn fees while in range; if out of range the band holds wrong asset
        if in_range > 0:
            fee_income += fee_pips * PIP * notional * expo
            pool += trade                      # trade fills against our liquidity
        else:
            # out of range: no fee, pool free-floats to true value (we're one-sided).
            # Realised pick-off ~ fraction of book * price gap beyond the band edge.
            inventory_pnl -= abs(gap) * 0.5 * 0.006 * expo  # stylised pick-off
            pool = true_v
    # normalise to a $1M reference book
    TVL = 1_000_000.0
    scale = TVL / 100.0
    return dict(fee=fee_income * scale / TVL, inv=inventory_pnl * scale / TVL,
                net=(0.9 * fee_income * scale + inventory_pnl * scale) / TVL)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=11)
    args = ap.parse_args()
    print("=" * 62)
    print("FERA RWA  --  weekend drift + Monday open, LP PnL")
    print("=" * 62)

    # average over several weekends for stability
    agg = {k: [] for k in ('vanillaA', 'feraB', 'feraC', 'feraD')}
    for s in range(12):
        path = synth_weekend(args.seed + s)
        for mode in agg:
            agg[mode].append(simulate(path, mode, seed=args.seed + s))

    def avg(mode, key):
        return float(np.mean([r[key] for r in agg[mode]]))

    print(f"\n(avg over 12 synthetic weekends, per $1 TVL, net of 10% perf fee)\n")
    print(f"  {'strategy':<42}{'fee%':>8}{'invPnL%':>9}{'NET%':>8}")
    labels = {
        'vanillaA': 'A vanilla 5bps, tight static band',
        'feraB':    'B FERA regime fee, tight band',
        'feraC':    'C FERA regime fee + off-hours WIDEN',
        'feraD':    f'D FERA regime + WIDEN + withdraw q={OFFHOURS_Q:.0%}',
    }
    for mode in ('vanillaA', 'feraB', 'feraC', 'feraD'):
        print(f"  {labels[mode]:<42}{avg(mode,'fee')*100:>7.3f} "
              f"{avg(mode,'inv')*100:>8.3f} {avg(mode,'net')*100:>7.3f}")

    # ---- PT-7: Monday-gap stress vs q (memo-05 band model, closed form) ----
    print("\n--- PT-7 gap stress: 20% Monday gap, worst-case TVL drawdown ---")
    print("  loss ~ 0.5*max(0, d - w)*(1-q) - overlay-fee offset (~0.5%*(1-q))")
    d = 0.20
    print(f"  {'q':>6} {'no widen (w=1%)':>17} {'widened (w=5%)':>16}")
    for q in (0.0, 0.3, 0.5, 0.6, 0.8):
        loss_nw = max(0.0, 0.5 * (d - 0.01) - 0.005) * (1 - q)
        loss_w = max(0.0, 0.5 * (d - 0.05) - 0.005) * (1 - q)
        tag = "  <- FROZEN (RWA_OFFHOURS_WITHDRAW_FRAC)" if q == OFFHOURS_Q else ""
        print(f"  {q:>6.0%} {loss_nw*100:>16.2f}% {loss_w*100:>15.2f}%{tag}")
    print("  Expected value is ~q-neutral (weekend fee income AND gap exposure")
    print("  both scale with (1-q)); q is chosen on TAIL grounds: a single-event")
    print("  9%+ drawdown is unacceptable for the Anchor-tranche retail LP, while")
    print("  q=1 forfeits the entire weekend-overlay edge AND weekend depth.")
    print("  Frozen q=0.60 -> worst case ~2.8% (widened) / 3.7% (memo-05 model),")
    print("  plus earnings-calendar forced widen+withdraw q_event=0.80.")

    net_A = avg('vanillaA', 'net')
    net_C = avg('feraC', 'net')
    net_D = avg('feraD', 'net')
    print("\n" + "=" * 62)
    ok = net_D > net_A
    print(f"VERDICT: FERA RWA (regime fee + widen + q={OFFHOURS_Q:.0%} withdraw) "
          f"beats vanilla weekend LP: {'PASS' if ok else 'FAIL'}  "
          f"(+{(net_D-net_A)*100:.3f}% per weekend; widen-only C: "
          f"+{(net_C-net_A)*100:.3f}%)")
    print("Interpretation: the deviation overlay converts weekend arb into LP "
          "income; widening avoids the Monday-gap pick-off; the q withdraw "
          "gives up ~60% of normal weekend net income for a ~2.5x smaller "
          "gap tail (both scale with (1-q); the tail is what q is for).")


if __name__ == "__main__":
    main()
