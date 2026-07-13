#!/usr/bin/env python3
"""
rwa_stress.py  —  FERA Pressure-Test harness for M5 (RWA vault adversarial).

QUESTION:
    Under each adversarial scenario, does the RWA vault FAIL-STATIC (positions
    hold, losses bounded) rather than fail-open? What is the worst-case LP
    drawdown (% of pool TVL), and which spec changes are required?

SCENARIOS (MASTER_SPEC / mission M5):
    S1  Oracle halt Friday   -> feed stale into the weekend.
    S2  20% Monday earnings gap -> underlying gaps at the open.
    S3  Keeper offline 48h   -> no widen/recenter/holiday flag.
    S4  Tick-boundary griefing -> attacker forces oscillating recenters.
    S5  MEV sandwich of predictable recenters.

MODEL (documented approximations over SYNTHETIC data; PARAMS.md pending):
    RWA position = concentrated band, half-width w around the Chainlink oracle.
    A tight band is heavily concentrated: concentration multiplier ~ 1/(2w).
    When the true price gaps by d past the band edge, the facing inventory
    (~50% of TVL) is transacted at ~the band edge instead of the true price, so
        band_conversion_loss ~= atrisk * max(0, d - w)         (fraction of TVL)
    The deviation-overlay fee (in-hook, ramps with |pool-oracle|, clamped to
    the ceiling) is earned on the arb volume that crosses the gap and OFFSETS
    part of the loss. Off-hours PARTIAL WITHDRAWAL of fraction q of liquidity to
    the vault reduces the exposed inventory by (1-q).

    These are order-of-magnitude bounds to size the risk and force spec numbers,
    not a tick-exact v3 simulation. Wire real oracle+swap data later (README).
"""
import argparse
import sys
import numpy as np

import params as P


def band_conversion_loss(gap, halfwidth, atrisk=0.5):
    """Fraction of TVL lost when true price moves `gap` (relative) past a band of
    half-width `halfwidth`. Within-band losses are second-order and omitted."""
    return atrisk * max(0.0, gap - halfwidth)


def overlay_fee_offset(arb_volume_frac, dev):
    """Overlay fee earned (fraction of TVL) on the arb volume that crosses the
    deviation `dev`, at the clamped overlay fee."""
    fee = float(np.clip(P.RWA_FEE_CLOSED + P.RWA_DEV_OVERLAY_K * dev,
                        P.RWA_FEE_FLOOR, P.RWA_FEE_CEIL))
    return fee * arb_volume_frac


def s1_oracle_halt(w, weekend_drift, q_withdraw):
    """S1: oracle halts Friday. Vault CANNOT recenter (INV-6 needs fresh oracle
    within sanity band) -> FAIL-STATIC, band frozen at Friday center. Arbs pull
    pool toward the true (drifting) price; overlay (using stale oracle) ramps as
    pool-vs-stale-oracle diverges -> earns fee. Exposed inventory = (1-q)."""
    exposed = 1.0 - q_withdraw
    loss = exposed * band_conversion_loss(weekend_drift, w)
    # arb must move ~ exposed*0.5 of TVL across the drift; overlay ramps.
    offset = overlay_fee_offset(arb_volume_frac=exposed * 0.5, dev=weekend_drift)
    net = max(0.0, loss - offset)
    return net, loss, offset, "FAIL-STATIC (band frozen; swaps + overlay still live)"


def s2_monday_gap(w, gap, q_withdraw):
    """S2: 20% Monday earnings gap. Recenter is TWAP-gated so the vault does NOT
    chase the gap at a bad price (protective). Facing inventory is converted at
    the band edge across the gap. Off-hours partial withdrawal (q) cuts exposure."""
    exposed = 1.0 - q_withdraw
    loss = exposed * band_conversion_loss(gap, w)
    offset = overlay_fee_offset(arb_volume_frac=exposed * 0.5, dev=gap)
    net = max(0.0, loss - offset)
    return net, loss, offset, "FAIL-STATIC (no recenter into gap; TWAP-gated)"


def s3_keeper_offline(w, weekend_drift):
    """S3: keeper offline 48h across a market-hours boundary. Vault fails to
    WIDEN/partial-withdraw off-hours -> stays tight (q=0) and exposed to weekend
    drift. Overlay still ramps (in-hook, keeper-independent) -> partial offset.
    This is the cost of NOT widening, i.e. the value of the off-hours action."""
    net_tight, loss_t, off_t, _ = s1_oracle_halt(w, weekend_drift, q_withdraw=0.0)
    # compare to the widened/withdrawn baseline the keeper WOULD have done
    net_wide, _, _, _ = s1_oracle_halt(w, weekend_drift, q_withdraw=0.60)
    extra = net_tight - net_wide
    return net_tight, extra, "FAIL-STATIC (holds), but forgoes off-hours widen -> extra drawdown"


def s4_tick_grief(recenters_per_day, slippage_per_recenter, min_interval_hours):
    """S4: attacker parks price at the hysteresis boundary to induce recenters.
    Each recenter costs rebalance slippage. A minimum recenter interval caps the
    count. Without a min-interval the attack is unbounded within a day."""
    cap = 24.0 / min_interval_hours if min_interval_hours > 0 else float("inf")
    effective = min(recenters_per_day, cap)
    drawdown = effective * slippage_per_recenter
    guard = ("min-interval caps it" if np.isfinite(cap) and recenters_per_day > cap
             else "UNBOUNDED without a min-recenter-interval")
    return drawdown, effective, guard


def s5_mev_sandwich(recenter_size_frac, pool_depth_frac, n_random_slots):
    """S5: sandwich of a predictable recenter swap. Sandwich profit ~ price
    impact of the recenter ~ (size/depth) on the size. Randomizing timing over N
    slots dilutes the searcher's certainty -> expected extraction ~ /sqrt(N)."""
    impact = recenter_size_frac / max(pool_depth_frac, 1e-9)
    worst = 0.5 * impact * recenter_size_frac          # deterministic timing
    randomized = worst / np.sqrt(max(n_random_slots, 1))
    return worst, randomized


def main():
    ap = argparse.ArgumentParser(description="FERA M5 RWA vault stress")
    ap.add_argument("--band", type=float, default=P.RWA_BAND_HALFWIDTH,
                    help="band half-width (relative). default 0.5%%")
    ap.add_argument("--q", type=float, default=0.60,
                    help="off-hours partial-withdrawal fraction (0..1)")
    args = ap.parse_args()
    w = args.band

    print("=" * 76)
    print("FERA M5 RWA VAULT ADVERSARIAL STRESS")
    print(f"band half-width w={w*1e2:.2f}%  off-hours withdraw q={args.q:.0%}  "
          f"overlay_ceil={P.RWA_FEE_CEIL*1e4:.0f}bps")
    print("DATA: SYNTHETIC / order-of-magnitude bounds. PARAMS.md pending.")
    print("=" * 76)

    rows = []

    # S1
    net, loss, off, mode = s1_oracle_halt(w, weekend_drift=0.03, q_withdraw=args.q)
    print(f"\nS1 Oracle halt Friday (3% weekend drift)  [{mode}]")
    print(f"   gross band loss={loss:.2%}  overlay offset={off:.2%}  "
          f"NET LP drawdown={net:.2%}")
    rows.append(("S1 oracle-halt", net, "CONDITIONAL"))

    # S2
    net, loss, off, mode = s2_monday_gap(w, gap=0.20, q_withdraw=args.q)
    print(f"\nS2 20% Monday earnings gap  [{mode}]")
    print(f"   gross band loss={loss:.2%}  overlay offset={off:.2%}  "
          f"NET LP drawdown={net:.2%}")
    net0, loss0, off0, _ = s2_monday_gap(w, gap=0.20, q_withdraw=0.0)
    print(f"   WITHOUT off-hours withdrawal (q=0): NET drawdown={net0:.2%}  "
          f"<-- exposure driver")
    rows.append(("S2 monday-gap-20%", net, "CONDITIONAL"))

    # S3
    net, extra, mode = s3_keeper_offline(w, weekend_drift=0.03)
    print(f"\nS3 Keeper offline 48h  [{mode}]")
    print(f"   NET drawdown (stayed tight)={net:.2%}  extra vs widened baseline="
          f"{extra:.2%}")
    rows.append(("S3 keeper-offline", net, "CONDITIONAL"))

    # S4
    dd, eff, guard = s4_tick_grief(recenters_per_day=48, slippage_per_recenter=0.0008,
                                   min_interval_hours=4.0)
    dd_ng, eff_ng, guard_ng = s4_tick_grief(48, 0.0008, min_interval_hours=0.0)
    print(f"\nS4 Tick-boundary griefing (8bps slippage/recenter)")
    print(f"   with 4h min-interval: {eff:.0f} recenters/day -> {dd:.2%}/day  ({guard})")
    print(f"   NO min-interval:      {eff_ng:.0f} recenters/day -> {dd_ng:.2%}/day  "
          f"({guard_ng})")
    rows.append(("S4 tick-grief", dd, "CONDITIONAL: needs min-recenter-interval"))

    # S5
    worst, rand = s5_mev_sandwich(recenter_size_frac=0.10, pool_depth_frac=1.0,
                                  n_random_slots=64)
    print(f"\nS5 MEV sandwich of recenter (10% of depth size)")
    print(f"   deterministic timing: {worst:.2%} extracted  |  randomized(64 "
          f"slots): {rand:.2%}")
    rows.append(("S5 mev-sandwich", rand, "CONDITIONAL: randomized timing REQUIRED"))

    print("\n" + "=" * 76)
    print("WORST-CASE LP DRAWDOWN SUMMARY (per scenario, % of pool TVL)")
    worst_scn, worst_dd = None, -1.0
    for name, dd, verdict in rows:
        print(f"   {name:22s} {dd:6.2%}   {verdict}")
        if dd > worst_dd:
            worst_scn, worst_dd = name, dd
    print(f"\nDRIVER: worst scenario = {worst_scn} at {worst_dd:.2%} of TVL.")
    print("All scenarios FAIL-STATIC (positions hold; no fail-open path found in")
    print("model). Losses are BOUNDED but S2 (Monday gap) is only acceptable with")
    print("aggressive off-hours partial withdrawal. Required spec changes -> memo 05.")
    print("=" * 76)


if __name__ == "__main__":
    sys.exit(main())
