#!/usr/bin/env python3
"""
FERA shadow run — automates docs/research/SHADOW_RUN_PLAN.md.

For each pool in approved_pools.json it (1) pulls live Robinhood Chain OHLCV + TVL from
GeckoTerminal, (2) runs the contract-faithful simulator (sim.py) over the trailing window at the
pool's MEASURED turnover, and (3) emits a per-pool recommendation: the best (limit-weight, width),
the DEFAULT (20%) vs LAUNCH (0-5%) preset call, and a launch-phase graduation signal. Output is a
dated JSON + a human line appended to shadow_report.jsonl — designed to run daily from cron or a
keeper (backend/keepers), zero manual steps.

  Run:   python3 shadow_run.py [--config approved_pools.json] [--days 30] [--out shadow_report.jsonl]
  Cron:  0 6 * * *  cd .../docs/research/backtest && python3 shadow_run.py >> shadow_run.cron.log 2>&1

PRE-DEPLOYMENT the pool list is seeded with curation-candidate pools (approved_pools.json).
POST-DEPLOYMENT the runner should build that list from the vault's curated/emissionsEligible set
(read via the Ponder indexer / API) so EVERY approved pool is shadowed automatically before its
parameters are frozen — replace load_pools() with an indexer query then. No pool's Active limit
budget should be frozen off the 20% default until it has ~2-4 weeks of green shadow runs (PASS
criteria in SHADOW_RUN_PLAN.md §"Pass / adjust criteria").

Stdlib only (Python 3.8+). Reuses sim.py in this directory.
"""
import json, os, sys, time, subprocess, urllib.request, argparse, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GT = "https://api.geckoterminal.com/api/v2/networks/{net}/pools/{addr}"


def _get(url, tries=4):
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "fera-shadowrun/1.0", "Accept": "application/json"})
            return json.load(urllib.request.urlopen(req, timeout=25))
        except Exception as e:
            if "429" in str(e) and k < tries - 1:
                time.sleep(15 * (k + 1)); continue
            raise


def load_pools(path):
    cfg = json.load(open(path))
    return cfg.get("network", "robinhood"), cfg.get("pools", [])


def fetch_pool(net, addr, days):
    """Return (candles [[ts,o,h,l,c,volUsd]...], tvl_usd) or (None, None)."""
    stats = _get(GT.format(net=net, addr=addr))
    a = stats.get("data", {}).get("attributes", {})
    tvl = float(a.get("reserve_in_usd") or 0)
    rows, before = [], None
    pages = max(1, min(12, (days * 288) // 1000 + 1))  # 288 5m-candles/day
    for _ in range(pages):
        u = GT.format(net=net, addr=addr) + "/ohlcv/minute?aggregate=5&limit=1000&currency=usd"
        if before:
            u += f"&before_timestamp={before}"
        d = _get(u)
        c = d.get("data", {}).get("attributes", {}).get("ohlcv_list", [])
        if not c:
            break
        rows.extend(c); before = min(r[0] for r in c) - 1
        time.sleep(2.5)
    seen = {r[0]: r for r in rows}
    return sorted(seen.values()), tvl


def launch_phase(candles):
    """Heuristic graduation signal: is the pool still in one-way price discovery?
    True (LAUNCH preset) if the trailing move is strongly one-directional with few reversals."""
    c = [r[4] for r in candles]
    if len(c) < 50:
        return True, "too-young/thin"
    tail = c[-min(len(c), 864):]  # ~3 days of 5m
    ret = tail[-1] / tail[0] - 1.0
    ups = sum(1 for i in range(1, len(tail)) if tail[i] > tail[i - 1])
    frac_up = ups / (len(tail) - 1)
    directional = abs(frac_up - 0.5) > 0.12 and abs(ret) > 0.5   # skewed steps + big net move
    return (directional, f"3d_ret={ret:+.1%} up_frac={frac_up:.2f}")


def run_sim(candles, turnover):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, dir=HERE) as f:
        json.dump({"candles": candles}, f); data = f.name
    out = data + ".out"
    try:
        subprocess.run(
            ["python3", os.path.join(HERE, "sim.py"), "--data", data, "--out", out,
             "--weights", "0,5,10,20,30", "--widths", "2,5,10", "--turnovers", f"{turnover:.3f}"],
            check=True, capture_output=True, text=True, timeout=300)
        d = json.load(open(out))
    finally:
        for p in (data, out):
            try: os.remove(p)
            except OSError: pass
    tv = d["meta"]["turnovers_per_day"][0]
    rows = [r for r in d["grid"] if abs(r["turnover_per_day"] - tv) < 1e-6]
    base = next(r for r in rows if r["w_pct"] == 0)
    best = max(rows, key=lambda r: r["ret_pct"])
    best_risk = max(rows, key=lambda r: r["ret_pct"] / max(r["max_dd_pct"], 1))
    at20 = max([r for r in rows if r["w_pct"] == 20], key=lambda r: r["ret_pct"], default=None)
    return {
        "hodl_ret_pct": round(d["benchmarks_by_turnover"][str(tv)]["hodl_5050_ret_pct"], 1),
        "base_only_ret_pct": round(base["ret_pct"], 1),
        "best": {"w": best["w_pct"], "width": best["width_pct"], "ret_pct": round(best["ret_pct"], 1), "dd_pct": round(best["max_dd_pct"], 1)},
        "best_risk_adj": {"w": best_risk["w_pct"], "width": best_risk["width_pct"], "ret_pct": round(best_risk["ret_pct"], 1), "dd_pct": round(best_risk["max_dd_pct"], 1)},
        "at_20pct_default": (round(at20["ret_pct"], 1) if at20 else None),
        "n_candles": d["meta"]["n_candles"],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(HERE, "approved_pools.json"))
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--out", default=os.path.join(HERE, "shadow_report.jsonl"))
    ap.add_argument("--now-ts", type=int, default=None, help="run timestamp (cron passes date +%s)")
    args = ap.parse_args()

    net, pools = load_pools(args.config)
    run_ts = args.now_ts if args.now_ts is not None else int(os.environ.get("FERA_RUN_TS", "0")) or None
    reports = []
    for p in pools:
        sym, addr = p["symbol"], p["address"]
        try:
            candles, tvl = fetch_pool(net, addr, args.days)
            if not candles or len(candles) < 50 or tvl <= 0:
                print(f"{sym:10} SKIP (candles={len(candles or [])} tvl=${tvl:,.0f})"); continue
            days = (candles[-1][0] - candles[0][0]) / 86400 or 1
            turnover = max(sum(r[5] for r in candles) / days / tvl, 0.1)
            sim = run_sim(candles, turnover)
            lp, why = launch_phase(candles)
            # DATA-DRIVEN recommendation (more principled than the price-trend proxy): if base-only
            # (limit-light) MATERIALLY beats the 20% default on this pool's own real data, the limit
            # band is an opportunity-cost drag here -> LAUNCH preset. Else the limit is earning its
            # keep -> DEFAULT. The price-trend heuristic is kept as secondary context/signal.
            base_r, at20 = sim["base_only_ret_pct"], sim["at_20pct_default"]
            limit_is_drag = at20 is not None and base_r > at20 * 1.10 and base_r > at20 + 5
            preset = "LAUNCH (0-5%)" if limit_is_drag else "DEFAULT (20%)"
            rec = {"run_ts": run_ts, "symbol": sym, "address": addr, "tvl_usd": round(tvl),
                   "turnover_per_day": round(turnover, 2),
                   "recommended_preset": preset, "limit_is_drag": limit_is_drag,
                   "trend_launch_phase": lp, "trend_signal": why, **sim}
            reports.append(rec)
            print(f"{sym:10} tvl=${tvl:>12,.0f} turnover={turnover:5.2f}x  best w={sim['best']['w']}/{sim['best']['width']} "
                  f"({sim['best']['ret_pct']:+.0f}%)  @20%={sim['at_20pct_default']}  -> {preset}  [{why}]")
        except Exception as e:
            print(f"{sym:10} ERROR {str(e)[:70]}")
    if reports:
        with open(args.out, "a") as fh:
            for r in reports:
                fh.write(json.dumps(r) + "\n")
        print(f"appended {len(reports)} rows to {os.path.basename(args.out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
