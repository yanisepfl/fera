#!/usr/bin/env python3
"""
meme_pnl.py  --  FERA MEME pool PnL vs vanilla v3/v4 LP.

Drives a MEME pool through quiet -> pump -> dump -> recover, computes the
dynamic fee per swap with the FROZEN on-chain EWMA fee engine (see
MECHANISM_SPEC.md 1.x / PARAMS.md), and compares fee-compensated full-range
LP PnL against vanilla flat 30bps and 100bps LPs on the SAME price path.

Real-data hook: pass --ticks CSV (columns: tick,quote_notional,zeroForOne) to
replay real chain swaps from Pressure-Test (V3). Falls back to a synthetic path.

Verdict printed at the end. Deterministic (seeded).
"""
import argparse
import math
import csv
import numpy as np

# ------------------------------------------------------------------ #
# FROZEN MEME fee parameters  (mirror of PARAMS.md; keep in sync)     #
# ------------------------------------------------------------------ #
FLOOR_PIPS      = 3400     # 0.34% (v2, PT-3: 0.9*34bp = 30.6bp > vanilla-30)
CEIL_PIPS       = 30000    # 3.00% symmetric ceiling
HARD_MAX_PIPS   = 50000    # 5.00% absolute cap (sell side during dumps)
SLOPE_PIPS_TICK = 200      # pips of fee per RMS tick of vol above dead-band (PROVISIONAL)
SIGMA0_TICKS    = 4        # dead-band: no vol premium below ~4 ticks RMS
SELL_K_PIPS     = 20000    # sell-side adder gain: up to +2.00% at imbalance = -1
LAM_UP          = 0.70     # asymmetric EWMA: fast attack  (vol rising)
LAM_DOWN        = 0.98     # asymmetric EWMA: slow release  (vol falling)
LAM_FLOW        = 0.90     # signed-flow EWMA decay
PERF_FEE        = 0.10     # 10% performance fee on collected LP fees

PIP = 1e-6  # 1 pip = 1e-6 of notional (hundredth of a bip)


class MemeFeeEngine:
    """Exact integer-friendly reference implementation of the on-chain engine.
    State fits one storage slot: (volEwma, flowEwma, lastTick, lastTs)."""
    def __init__(self, floor_pips=FLOOR_PIPS):
        self.vol = 0.0     # EWMA of r^2   (tick^2)
        self.flow = 0.0    # EWMA of signed r (ticks)
        self.last_tick = None
        self.floor = floor_pips

    def quote_fee(self, zero_for_one):
        """beforeSwap: returns fee in pips using CURRENT stored state."""
        sigma = math.sqrt(self.vol)
        base = self.floor + SLOPE_PIPS_TICK * max(0.0, sigma - SIGMA0_TICKS)
        base = min(max(base, self.floor), CEIL_PIPS)
        imb = self.flow / (sigma + 1.0)          # in ~[-1, 1]
        if zero_for_one:                          # sell (price-decreasing dir)
            adder = SELL_K_PIPS * max(0.0, -imb)
            fee = min(base + adder, HARD_MAX_PIPS)
        else:
            fee = base
        return fee, sigma, imb

    def update(self, new_tick):
        """afterSwap: update EWMA state from realised tick move."""
        if self.last_tick is None:
            self.last_tick = new_tick
            return
        r = new_tick - self.last_tick
        r2 = r * r
        lam = LAM_UP if r2 > self.vol else LAM_DOWN
        self.vol = lam * self.vol + (1 - lam) * r2
        self.flow = LAM_FLOW * self.flow + (1 - LAM_FLOW) * r
        self.last_tick = new_tick


def synth_path(seed=7):
    """Synthetic MEME session: quiet -> pump -> dump -> chop, per-swap.
    Returns list of (tick, quote_notional, zero_for_one)."""
    rng = np.random.default_rng(seed)
    swaps = []
    tick = 0.0
    # regime schedule: (n_swaps, drift_ticks_per_swap, vol_ticks, mean_notional)
    regimes = [
        (400,  0.0,  3.0,  2_000),   # quiet accumulation
        (150,  9.0,  35.0, 12_000),  # PUMP: strong up-drift, high vol, size up
        (120, -16.0, 55.0, 20_000),  # DUMP: violent one-sided sell-off
        (330,  0.0,  8.0,  4_000),   # post-dump chop
    ]
    for n, drift, vol, notm in regimes:
        for _ in range(n):
            step = drift + rng.normal(0, vol)
            tick += step
            # direction: down-step => a sell (zeroForOne) dominates that swap
            z4o = step < 0
            notional = max(200.0, rng.normal(notm, notm * 0.4))
            swaps.append((tick, notional, z4o))
    return swaps


def load_csv(path):
    out = []
    with open(path) as f:
        for row in csv.DictReader(f):
            out.append((float(row["tick"]), float(row["quote_notional"]),
                        str(row["zeroForOne"]).lower() in ("1", "true", "yes")))
    return out


def cpmm_value(P, k):
    """Full-range x*y=k position value in quote units at price P."""
    return 2.0 * math.sqrt(k * P)


def run(swaps, label, floor_pips=FLOOR_PIPS, quiet=False):
    eng = MemeFeeEngine(floor_pips=floor_pips)
    # price P from tick: P = 1.0001**tick
    P0 = 1.0001 ** swaps[0][0]
    TVL0 = 1_000_000.0                    # $1M initial pool value (quote units)
    k = (TVL0 / 2.0) ** 2 / P0            # from value = 2*sqrt(kP0) = TVL0
    fee_dyn = 0.0
    fee_v30 = 0.0
    fee_v100 = 0.0
    fees_pips = []
    eng.update(swaps[0][0])
    for tick, notional, z4o in swaps[1:]:
        fee, sigma, imb = eng.quote_fee(z4o)
        fees_pips.append(fee)
        fee_dyn  += fee * PIP * notional
        fee_v30  += 0.0030 * notional
        fee_v100 += 0.0100 * notional
        eng.update(tick)
    P_end = 1.0001 ** swaps[-1][0]
    # IL: LP value vs HODL of initial reserves, same for all three (same path)
    x0 = math.sqrt(k / P0); y0 = math.sqrt(k * P0)
    hodl = y0 + x0 * P_end
    lpval = cpmm_value(P_end, k)
    il = lpval / hodl - 1.0

    y_dyn  = fee_dyn  / TVL0
    y_v30  = fee_v30  / TVL0
    y_v100 = fee_v100 / TVL0
    net_dyn  = (1 - PERF_FEE) * y_dyn + il       # FERA takes 10% perf fee
    net_v30  = y_v30  + il                        # vanilla: no perf fee
    net_v100 = y_v100 + il
    avg_fee_pips = float(np.mean(fees_pips))

    if quiet:
        return dict(avg_fee_pips=avg_fee_pips, net_dyn=net_dyn, net_v30=net_v30,
                    net_v100=net_v100, beats30=net_dyn > net_v30,
                    beats100=net_dyn > net_v100)
    print(f"\n=== {label} ===")
    print(f"  swaps                : {len(swaps):>10,}")
    print(f"  price move           : {(P_end/P0-1)*100:>9.2f}%   (end/start)")
    print(f"  avg dynamic fee      : {avg_fee_pips/100:>9.2f} bps")
    print(f"  max dynamic fee      : {max(fees_pips)/100:>9.2f} bps")
    print(f"  impermanent loss     : {il*100:>9.3f}%")
    print(f"  fee yield  FERA(dyn) : {y_dyn*100:>9.3f}%   (gross, /TVL)")
    print(f"  fee yield  vanilla30 : {y_v30*100:>9.3f}%")
    print(f"  fee yield  vanilla100: {y_v100*100:>9.3f}%")
    print(f"  NET LP  FERA (0.9*dyn+IL) : {net_dyn*100:>8.3f}%")
    print(f"  NET LP  vanilla 30bps     : {net_v30*100:>8.3f}%")
    print(f"  NET LP  vanilla 100bps    : {net_v100*100:>8.3f}%")
    beats30  = net_dyn > net_v30
    beats100 = net_dyn > net_v100
    print(f"  FERA beats vanilla-30bps  : {'YES' if beats30 else 'NO'}")
    print(f"  FERA beats vanilla-100bps : {'YES' if beats100 else 'NO'}")
    return dict(avg_fee_pips=avg_fee_pips, net_dyn=net_dyn, net_v30=net_v30,
                net_v100=net_v100, beats30=beats30, beats100=beats100)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ticks", help="CSV: tick,quote_notional,zeroForOne (real data)")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    print("=" * 62)
    print("FERA MEME  --  fee-compensated LP PnL vs vanilla v3/v4")
    print("=" * 62)

    if args.ticks:
        swaps = load_csv(args.ticks)
        res = [run(swaps, "REAL DATA")]
    else:
        # sessions: violent / quiet / dead-calm
        res = []
        res.append(run(synth_path(args.seed), "SESSION A  pump+dump (synthetic)"))
        # quiet-only pool
        rng = np.random.default_rng(args.seed + 1)
        quiet = []
        t = 0.0
        for _ in range(900):
            step = rng.normal(0, 3.0)
            t += step
            quiet.append((t, max(200.0, rng.normal(2500, 800)), step < 0))
        res.append(run(quiet, "SESSION B  quiet pool (synthetic)"))
        # dead-calm pool: sigma < SIGMA0 dead-band, fee pinned at the floor --
        # the PT-3 worst case (memo 03: 0/200 calm paths at the old 30bp floor)
        rng = np.random.default_rng(args.seed + 2)
        calm = []
        t = 0.0
        for _ in range(900):
            step = rng.normal(0, 1.5)
            t += step
            calm.append((t, max(200.0, rng.normal(2500, 800)), step < 0))
        res.append(run(calm, "SESSION C  dead-calm pool (fee at floor)"))

        # PT-3: floor decision -- old 30bp floor vs frozen 34bp floor on C
        old = run(calm, "", floor_pips=3000, quiet=True)
        new = run(calm, "", floor_pips=3400, quiet=True)
        print("\n--- PT-3 floor check on SESSION C (dead calm) ---")
        print(f"  floor 3000 (old): net {old['net_dyn']*100:+.3f}% vs "
              f"vanilla-30 {old['net_v30']*100:+.3f}%  -> "
              f"{'beats' if old['beats30'] else 'LOSES'}")
        print(f"  floor 3400 (v2) : net {new['net_dyn']*100:+.3f}% vs "
              f"vanilla-30 {new['net_v30']*100:+.3f}%  -> "
              f"{'beats' if new['beats30'] else 'LOSES'}")
        print("  0.9*34bp = 30.6bp > 30bp: the 10% perf-fee hurdle is cleared "
              "at the floor itself.")

    print("\n" + "=" * 62)
    ok = all(r["beats30"] for r in res)
    print(f"VERDICT: FERA regime LP beats vanilla 30bps net of 10% perf "
          f"fee in ALL sessions (incl. dead calm): {'PASS' if ok else 'FAIL'}")
    print("Note: vs the 100bps tier FERA wins only when realised vol is high "
          "enough that 0.9*avg_dyn_fee > 100bps (see SESSION A vs B); on a "
          "truly quiet pair the pool-eligibility rule applies (SPEC 5).")


if __name__ == "__main__":
    main()
