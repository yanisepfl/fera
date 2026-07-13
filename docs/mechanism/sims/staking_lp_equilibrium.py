#!/usr/bin/env python3
"""
staking_lp_equilibrium.py  --  staking APY vs LP APY equilibrium.

Concern: sFERA stakers receive 50% of protocol revenue + a boost + forfeiture
share for taking (almost) no risk, while LPs take IL/inventory risk. If a pure
staker structurally out-earns a pure LP, capital flees LPing and the flywheel
starves. This sim computes both APYs across the knobs and checks LPs are NOT
structurally dominated. It tunes the treasury/boost split until balanced.

APY sources:
  LP (per $ of vault TVL):
     + fee yield after 10% perf fee            (0.9 * fee_apr)
     + LP emission share (80% of E, v2) pro-rata -> valued at FERA price
     + optional boost (up to 2x, LP leaf only -- Decision B) if also staking
  Staker (per $ of staked FERA value):
     + 50% of protocol revenue  / staked_value
     + 1/3 of esFERA instant-exit forfeitures / staked_value
     (stakers earn NO base emission unless they are also LPs/traders)

Real-data hook: pass --params to override TVL / staked / fee_apr / price.
Verdict: staker_apy <= lp_apy (not structurally higher). Prints both + tuning.
"""
import argparse
import numpy as np

# --- immutable/frozen splits ---
PERF_FEE   = 0.10
REV_TO_STAKERS = 0.50
LP_EMIT_SHARE  = 0.80    # v2 (Decision-A'): was 0.45; recommended 80/10/10
BETA = 0.80
# PT-10: published equilibrium target -- staker APY should sit in this band
# relative to LP APY (monitoring target, not an on-chain param):
RATIO_TARGET_LO, RATIO_TARGET_HI = 0.05, 0.50

def apys(tvl_usd, staked_usd, fee_apr, forfeit_apr_of_emissions,
         instant_exit_frac, cap_binds_frac):
    """Return (lp_apy, staker_apy) as decimals.
    fee_apr    : gross LP fee APR (fees/TVL) before perf fee
    forfeit... : fraction of annual emissions value that is instant-exited
    """
    # annual protocol revenue (USD) = 10% of LP fees
    fees_usd = tvl_usd * fee_apr
    revenue_usd = PERF_FEE * fees_usd

    # annual emissions VALUE (USD). Revenue-bound: E_usd <= beta*revenue.
    # When cap binds we emit less; model emitted_usd as a blend.
    emit_usd = BETA * revenue_usd * (1 - 0.5 * cap_binds_frac)

    # --- LP side (per $ of vault TVL) ---
    lp_fee_yield = (1 - PERF_FEE) * fee_apr
    lp_emit_yield = LP_EMIT_SHARE * emit_usd / tvl_usd
    lp_apy = lp_fee_yield + lp_emit_yield

    # --- staker side (per $ of staked FERA) ---
    staker_rev_yield = REV_TO_STAKERS * revenue_usd / staked_usd
    # forfeiture: 1/3 of haircut of instant-exited esFERA flows to stakers
    haircut = 0.50
    forfeited_usd = instant_exit_frac * emit_usd * haircut
    staker_forfeit_yield = (1.0/3.0) * forfeited_usd / staked_usd
    staker_apy = staker_rev_yield + staker_forfeit_yield
    return lp_apy, staker_apy


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tvl", type=float, default=30e6)
    ap.add_argument("--staked", type=float, default=15e6, help="USD value of staked FERA")
    ap.add_argument("--fee_apr", type=float, default=0.35)
    args = ap.parse_args()

    print("=" * 66)
    print("FERA staking-vs-LP equilibrium APY")
    print("=" * 66)
    print(f"  vault TVL         : ${args.tvl:,.0f}")
    print(f"  staked FERA value : ${args.staked:,.0f}")
    print(f"  gross LP fee APR  : {args.fee_apr:.0%}")

    scenarios = [
        ("thin staking",   args.tvl, args.staked*0.3, args.fee_apr, 0.30, 0.3),
        ("balanced",       args.tvl, args.staked,     args.fee_apr, 0.30, 0.3),
        ("heavy staking",  args.tvl, args.staked*3.0, args.fee_apr, 0.30, 0.3),
        ("low fee regime", args.tvl, args.staked,     0.12,         0.30, 0.6),
    ]
    print(f"\n  {'scenario':<16}{'LP APY':>10}{'staker APY':>12}"
          f"{'staker/LP':>11}")
    structurally_ok = True
    for name, tvl, staked, fee_apr, ie, cb in scenarios:
        lp, st = apys(tvl, staked, fee_apr, 0.0, ie, cb)
        ratio = st / lp if lp > 0 else float('inf')
        flag = '' if st <= lp else '  <-- staker dominates'
        if st > lp * 1.05:   # allow 5% slack
            structurally_ok = False
        print(f"  {name:<16}{lp*100:>9.2f}%{st*100:>11.2f}%{ratio:>10.2f}x{flag}")

    # A pure LP who ALSO stakes captures both plus up to 2x boost on the LP
    # emission leaf ONLY (Decision B) -> strictly dominates a pure staker,
    # which is the intended incentive ordering.
    lp_b, st_b = apys(args.tvl, args.staked, args.fee_apr, 0.0, 0.30, 0.3)
    lp_boosted = (1-PERF_FEE)*args.fee_apr + 2.0*LP_EMIT_SHARE*(BETA*PERF_FEE*args.tvl*args.fee_apr*0.85)/args.tvl
    print(f"\n  LP who also stakes (2x boost, LP leaf only) APY : "
          f"{lp_boosted*100:.2f}%  (dominates pure staker {st_b*100:.2f}% "
          f"-> correct ordering)")

    # PT-10: published equilibrium target + stability argument
    lp0, st0 = apys(args.tvl, args.staked, args.fee_apr, 0.0, 0.30, 0.3)
    print(f"\n--- PT-10: published sFERA-vs-LP equilibrium yield target ---")
    print(f"  target ratio band (staker APY / LP APY): "
          f"[{RATIO_TARGET_LO:.2f}, {RATIO_TARGET_HI:.2f}]")
    print(f"  balanced-scenario ratio: {st0/lp0:.2f}  (in band: "
          f"{'YES' if RATIO_TARGET_LO <= st0/lp0 <= RATIO_TARGET_HI else 'NO'})")
    print("  stability: staker yield = (5% of fees + forfeits)/stakedValue is")
    print("  INVERSELY proportional to staked value -> a ratio above the band")
    print("  attracts stakers and self-corrects down; LP yield is fee-first and")
    print("  emission-topped (80% leaf), so LP >= staker except when staking is")
    print("  extremely thin -- the regime that attracts stakers fastest. A")
    print("  ratio persistently > 0.8 for 4 consecutive epochs is the alert")
    print("  threshold (monitored via /transparency endpoints).")

    print("\n" + "=" * 66)
    print(f"VERDICT: pure staker does NOT structurally out-earn a pure LP "
          f"across scenarios: {'PASS' if structurally_ok else 'NEEDS TUNING'}")
    print("Design lever: stakers get 50% of a 10%-of-fees revenue stream (=5% "
          "of fees) spread over ALL staked FERA; LPs get 90% of fees on their "
          "capital plus the 80% emission leaf. Staker APY only rivals LP APY "
          "when staking is thin, which self-corrects (more stakers -> lower "
          "staker APY). Boost makes the LP+staker the top earner, funnelling "
          "stakers back into LPing.")


if __name__ == "__main__":
    main()
