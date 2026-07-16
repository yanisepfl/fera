#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FERA base+limit vault strategy backtest simulator (pure Python 3.8, stdlib only).

Mirrors the REAL contract math from:
  contracts/src/libraries/FeeLogic.sol      - MEME dynamic fee curve + widthMultiplierBps
  contracts/src/libraries/FeraConstants.sol - all magnitudes below
  contracts/src/FeraHook.sol                - _updateEwma (asymmetric-lambda ratchet EWMA of r^2)
  contracts/src/libraries/VaultOps.sol      - cbRebalanceLimit / cbRebalanceBase shape

Model: ONE MEME Active tranche, NAV normalized to 1.0 in quote terms.
  (1-w) of capital in the vol-adaptive BASE band (half = 2624 ticks x mult(sigma), mult in [0.5, 25]),
  w budgeted to a NARROW SINGLE-SIDED LIMIT band on the deficit side (buy band just below spot when
  inventory is quote-heavy, sell band just above when token-heavy).

CLI:
  python3 sim.py --data candles.json --out results.json \
      [--weights 0,5,10,15,20,25,30,40,50] [--widths 1,2,5,10,15] [--shares 20,50,100] \
      [--start-ts X --end-ts Y] [--synthetic gbm:<volPct>:<driftPct>:<candles>] [--seed 42] [--sanity]

Data: {"candles": [[ts, o, h, l, c, volQuote], ...]}  (ts seconds)
Synthetic: gbm:<annualizedVol%>:<annualizedDrift%>:<nCandles>  (5m candles, deterministic seed)

All simplifications vs the contracts are documented in MECHANICS_NOTES below.
"""
import argparse
import json
import math
import random
import sys
import time

LN_T = math.log(1.0001)
INF = float("inf")

# ---------------------------------------------------------------------------
# Contract constants (FeraConstants.sol) -- float mirrors of the on-chain ints
# ---------------------------------------------------------------------------
MEME_FEE_FLOOR = 3400 / 1e6          # MEME_FEE_FLOOR_PIPS  (0.34%)
MEME_FEE_CEIL = 30000 / 1e6          # MEME_FEE_CEIL_PIPS   (3.00%)
MEME_FEE_SLOPE = 200 / 1e6           # MEME_FEE_SLOPE_PIPS_PER_TICK (per tick of sigma)
MEME_FEE_SIGMA0 = 4.0                # MEME_FEE_SIGMA0_TICKS (dead-band)
LAM_UP = 45875 / 65536.0             # MEME_VOL_LAMBDA_UP   ~0.70 (fast attack)
LAM_DOWN = 64225 / 65536.0           # MEME_VOL_LAMBDA_DOWN ~0.98 (slow release)
VOL_EWMA_CLAMP = float(2 ** 34)      # MEME_VOL_CLAMP=2^50 on volEwmaX (Q16) => EWMA(r^2) <= 2^34

BASE_HALF_TICKS = 2624.0             # ACTIVE_BASE_HALF_TICKS  (+-30%)
WM_MIN = 0.5                         # VOL_WIDTH_MULT_MIN_BPS_DEFAULT / BPS
WM_MAX = 25.0                        # VOL_WIDTH_MULT_MAX_BPS_DEFAULT / BPS
WM_SIGMA0 = 4.0                      # VOL_WIDTH_MULT_SIGMA0_TICKS
WM_SLOPE = 300 / 10000.0             # VOL_WIDTH_MULT_SLOPE_BPS_PER_TICK / BPS (x per tick)

MIN_LIMIT_INTERVAL = 1800            # MEME_MIN_REBALANCE_INTERVAL_SEC
OOR_DWELL = 3600                     # MEME_OOR_DWELL_SEC
BASE_RECENTER_MIN_INTERVAL = 21600   # MEME_BASE_RECENTER_MIN_INTERVAL_SEC
MAX_IL_FRAC = 300 / 10000.0          # MAX_IL_BPS_PER_RECENTER (3% of NAV notional per recenter)
RECENTER_SLIP = 100 / 10000.0        # MAX_REBALANCE_SLIPPAGE_BPS treated as a FLAT 1% penalty
TWAP_WINDOW = 1800                   # REBALANCE_TWAP_WINDOW_SEC
TWAP_SANITY = 500 / 10000.0          # REBALANCE_TWAP_SANITY_BPS (+-5% spot vs TWAP)
TICK_BOUND = 887000.0                # ~ TickMath usable range clamp

SIM_VERSION = "1.0.0"


def width_mult(sigma):
    """FeeLogic.widthMultiplierBps with the default governance clamp [0.5x, 25x]."""
    if sigma <= WM_SIGMA0:
        return WM_MIN
    m = WM_MIN + WM_SLOPE * (sigma - WM_SIGMA0)
    return WM_MAX if m > WM_MAX else m


def fee_rate(sigma):
    """FeeLogic._memeFee base curve: clamp(FLOOR + SLOPE*max(0, sigma-SIGMA0), FLOOR, CEIL).
    (Sell-side adder NOT modeled -- candle data has no per-swap signed flow; see notes.)"""
    if sigma <= MEME_FEE_SIGMA0:
        return MEME_FEE_FLOOR
    f = MEME_FEE_FLOOR + MEME_FEE_SLOPE * (sigma - MEME_FEE_SIGMA0)
    return MEME_FEE_CEIL if f > MEME_FEE_CEIL else f


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
def load_candles(path, start_ts=None, end_ts=None):
    with open(path) as fh:
        raw = json.load(fh)
    rows = raw["candles"] if isinstance(raw, dict) else raw
    out = []
    for r in rows:
        ts, o, h, l, c, v = int(r[0]), float(r[1]), float(r[2]), float(r[3]), float(r[4]), float(r[5])
        if o <= 0.0 or c <= 0.0 or v < 0.0:
            continue
        if start_ts is not None and ts < start_ts:
            continue
        if end_ts is not None and ts > end_ts:
            continue
        lo = min(l if l > 0.0 else min(o, c), o, c)
        hi = max(h, o, c)
        out.append((ts, o, hi, lo, c, v))
    out.sort(key=lambda r: r[0])
    if len(out) < 2:
        raise SystemExit("need at least 2 usable candles")
    return out


def gen_gbm(vol_pct, drift_pct, n, seed=42, dt_sec=300, p0=1.0):
    """Deterministic GBM OHLCV: annualized vol%/drift%, 5m candles by default.
    volQuote is arbitrary-scaled (~0.02 quote per candle base) -- fee income is linear in it."""
    rnd = random.Random(seed)
    sig = vol_pct / 100.0
    mu = drift_pct / 100.0
    dt_y = dt_sec / (365.0 * 24 * 3600)
    sdt = sig * math.sqrt(dt_y)
    candles = []
    p = p0
    ts = 1_700_000_000
    for _ in range(n):
        z = rnd.gauss(0.0, 1.0)
        o = p
        c = o * math.exp((mu - 0.5 * sig * sig) * dt_y + sdt * z)
        wh = abs(rnd.gauss(0.0, 1.0)) * 0.5 * sdt
        wl = abs(rnd.gauss(0.0, 1.0)) * 0.5 * sdt
        h = max(o, c) * math.exp(wh)
        l = min(o, c) * math.exp(-wl)
        v = 0.02 * (0.25 + abs(z) + 0.5 * (abs(rnd.gauss(0.0, 1.0))))
        candles.append((ts, o, h, l, c, v))
        ts += dt_sec
        p = c
    return candles


# ---------------------------------------------------------------------------
# Precompute (shared across every grid combo -- keeps the inner loop lean)
# ---------------------------------------------------------------------------
def precompute(candles):
    n = len(candles)
    ts = [r[0] for r in candles]
    o = [r[1] for r in candles]
    h = [r[2] for r in candles]
    l = [r[3] for r in candles]
    c = [r[4] for r in candles]
    v = [r[5] for r in candles]

    tick_c = [math.log(x) / LN_T for x in c]
    sqrt_c = [math.sqrt(x) for x in c]

    # Hook EWMA (FeraHook._updateEwma), per-CANDLE approximation of the per-swap update:
    # r = close_tick - prev_close_tick; lambda ratchet: fast attack if r^2 > EWMA, slow release else.
    sig_pre = [0.0] * n    # sigma BEFORE candle i trades (drives candle i's fee, like beforeSwap)
    sig_post = [0.0] * n   # sigma AFTER candle i (drives band widths chosen at candle i close)
    ewma = 0.0
    prev = math.log(o[0]) / LN_T
    for i in range(n):
        sig_pre[i] = math.sqrt(ewma)
        tc = tick_c[i]
        r = tc - prev
        r2 = r * r
        lam = LAM_UP if r2 > ewma else LAM_DOWN
        ewma = lam * ewma + (1.0 - lam) * r2
        if ewma > VOL_EWMA_CLAMP:
            ewma = VOL_EWMA_CLAMP
        sig_post[i] = math.sqrt(ewma)
        prev = tc

    fee = [fee_rate(s) for s in sig_pre]
    # TURNOVER FEE MODEL (v2 — fixes the raw-volQuote units bug the sweep round caught):
    # CEX volume supplies only the SHAPE of when volume happens; the LEVEL is set by a
    # pool-turnover parameter (pool daily volume as a multiple of pool TVL). volshape[i] is
    # candle i's volume in average-day units (sum = total_days), so
    #   our_fee[i] = fee[i] * turnover/day * NAV_prev * volshape[i] * overlap
    # integrates to fee*turnover*NAV per day at full overlap — share-invariant by construction
    # (a bigger share of a smaller pool at equal turnover earns the same per dollar).
    total_days = max((ts[-1] - ts[0]) / 86400.0, 1e-9)
    volsum = sum(v)
    volshape = [(x / volsum) * total_days if volsum > 0.0 else 0.0 for x in v]

    # Rolling TWAP of the close tick over TWAP_WINDOW (contract: tick-cumulative oracle).
    if n > 1:
        diffs = sorted(ts[i + 1] - ts[i] for i in range(n - 1))
        dt_med = diffs[len(diffs) // 2] or 300
    else:
        dt_med = 300
    k = max(1, int(round(TWAP_WINDOW / float(dt_med))))
    twap_p = [0.0] * n
    acc = 0.0
    for i in range(n):
        acc += tick_c[i]
        if i >= k:
            acc -= tick_c[i - k]
        m = acc / (k if i >= k - 1 else i + 1)
        twap_p[i] = math.exp(m * LN_T)

    return {
        "n": n, "ts": ts, "o": o, "h": h, "l": l, "c": c, "v": v,
        "tick_c": tick_c, "sqrt_c": sqrt_c, "sig_pre": sig_pre, "sig_post": sig_post,
        "fee": fee, "volshape": volshape, "total_days": total_days,
        "twap_p": twap_p, "dt_med": dt_med, "p0": o[0],
    }


# ---------------------------------------------------------------------------
# Strategy engine
# ---------------------------------------------------------------------------
def _place_limit(lt, lq, p, t, h_lim):
    """Single-sided limit on the deficit side (VaultOps.cbRebalanceLimit, skew pushed fully
    one-sided per the research model). Quote-heavy -> buy band [t-h, t] (quote only);
    token-heavy -> sell band [t, t+h] (token only). Minority asset stays in reserve.
    Returns (side, pl, pu, amt, lt, lq); side: 1 buy / -1 sell / 0 none."""
    if lq >= lt * p:
        if lq <= 0.0:
            return 0, 0.0, 0.0, 0.0, lt, lq
        return 1, math.exp((t - h_lim) * LN_T), p, lq, lt, 0.0
    if lt <= 0.0:
        return 0, 0.0, 0.0, 0.0, lt, lq
    return -1, p, math.exp((t + h_lim) * LN_T), lt, 0.0, lq


def run_strategy(P, w, width_pct, turnover, debug=False):
    """One backtest run. w in [0,1] = limit weight; width_pct = limit band extent in %;
    turnover = pool daily volume as a multiple of pool TVL (fee model v2 — see precompute)."""
    n = P["n"]
    ts_l = P["ts"]; h_l = P["h"]; l_l = P["l"]; c_l = P["c"]
    tick_l = P["tick_c"]; sp_l = P["sqrt_c"]; sigpost = P["sig_post"]
    fee_l = P["fee"]; volshape = P["volshape"]; twap_l = P["twap_p"]

    p0 = P["p0"]
    t0 = math.log(p0) / LN_T
    h_lim = math.log1p(width_pct / 100.0) / LN_T  # width% below/above spot, in ticks

    # --- base band (initial sigma = 0 -> mult floor 0.5x, like a fresh pool) ---
    half = BASE_HALF_TICKS * WM_MIN
    ba_t = max(t0 - half, -TICK_BOUND)
    bb_t = min(t0 + half, TICK_BOUND)
    pa = math.exp(ba_t * LN_T); pb = math.exp(bb_t * LN_T)
    sa = math.sqrt(pa); sb = math.sqrt(pb); isb = 1.0 / sb
    sp0 = math.sqrt(p0)
    denom0 = 2.0 * sp0 - sa - p0 * isb
    L = (1.0 - w) / denom0 if (w < 1.0 and denom0 > 0.0) else 0.0
    bt = 0.0; bq = 0.0  # base-side reserve (token, quote)

    # --- limit inventory: starts all-quote (w) -> initial buy band below spot ---
    lt = 0.0; lq = w
    lb_side, lb_pl, lb_pu, lb_amt, lt, lq = _place_limit(lt, lq, p0, t0, h_lim)
    lb_f = 0.0
    lb_hw = lb_pu if lb_side == 1 else lb_pl

    fees_q = 0.0
    nav = 1.0
    nav_prev = 1.0
    realized_loss = 0.0
    last_lim = ts_l[0]
    last_rec = -1e18
    oor_since = None
    n_rec = 0; n_fills = 0; n_repl = 0; tir = 0
    peak = 1.0; mdd = 0.0; min_bal = 0.0
    nav = 1.0

    for i in range(n):
        lo = l_l[i]; hi = h_l[i]; pc = c_l[i]; sp = sp_l[i]; t_now = ts_l[i]

        # ---- limit fill along the candle path (only extreme matters; actions are EoC) ----
        if lb_side == 1:
            if lo < lb_hw:
                m = lo if lo > lb_pl else lb_pl
                if m < lb_hw:
                    fnew = (lb_pu - m) / (lb_pu - lb_pl)
                    if fnew > 1.0:
                        fnew = 1.0
                    df = fnew - lb_f
                    if df > 0.0:
                        gm = math.sqrt(lb_hw * m)
                        lt += lb_amt * df / gm       # quote -> token at gm (value-conserving)
                        lb_f = fnew
                        lb_hw = m
                        if fnew >= 1.0 - 1e-12:
                            n_fills += 1
        elif lb_side == -1:
            if hi > lb_hw:
                m = hi if hi < lb_pu else lb_pu
                if m > lb_hw:
                    fnew = (m - lb_pl) / (lb_pu - lb_pl)
                    if fnew > 1.0:
                        fnew = 1.0
                    df = fnew - lb_f
                    if df > 0.0:
                        gm = math.sqrt(lb_hw * m)
                        lq += lb_amt * df * gm       # token -> quote at gm
                        lb_f = fnew
                        lb_hw = m
                        if fnew >= 1.0 - 1e-12:
                            n_fills += 1

        # ---- fee income (turnover model v2): fee x turnover/day x NAV_prev x vol-shape x overlap ----
        shp = volshape[i]
        if shp > 0.0:
            span = hi - lo
            if span <= 1e-15 * pc:  # high == low guard
                inr = (L > 0.0 and pa <= pc <= pb) or (lb_side != 0 and lb_pl <= pc <= lb_pu)
                ov = 1.0 if inr else 0.0
            else:
                ov_len = 0.0
                if L > 0.0:
                    a = pa if pa > lo else lo
                    b = pb if pb < hi else hi
                    if b > a:
                        ov_len = b - a
                if lb_side != 0:
                    a2 = lb_pl if lb_pl > lo else lo
                    b2 = lb_pu if lb_pu < hi else hi
                    if b2 > a2:
                        ov_len += b2 - a2
                        if L > 0.0:  # subtract base/limit double count
                            a3 = max(pa, lb_pl, lo)
                            b3 = min(pb, lb_pu, hi)
                            if b3 > a3:
                                ov_len -= b3 - a3
                ov = ov_len / span
                if ov > 1.0:
                    ov = 1.0
            if ov > 0.0:
                # fee base = PRINCIPAL marked to market (nav minus the fee pot): collected fees sit
                # in reserve and are never redeployed (simplification #18), so they must not compound.
                fees_q += fee_l[i] * turnover * max(nav_prev - fees_q, 0.0) * shp * ov

        # ---- end-of-candle: limit re-place (min 1800s between limit actions) ----
        if lb_side != 0:
            if (lb_f >= 1.0 - 1e-9 or pc < lb_pl or pc > lb_pu) and (t_now - last_lim) >= MIN_LIMIT_INTERVAL:
                rem = lb_amt * (1.0 - lb_f)
                if lb_side == 1:
                    lq += rem
                else:
                    lt += rem
                lb_side, lb_pl, lb_pu, lb_amt, lt, lq = _place_limit(lt, lq, pc, tick_l[i], h_lim)
                lb_f = 0.0
                lb_hw = lb_pu if lb_side == 1 else lb_pl
                last_lim = t_now
                n_repl += 1
        elif (lt > 0.0 or lq > 0.0) and (t_now - last_lim) >= MIN_LIMIT_INTERVAL:
            lb_side, lb_pl, lb_pu, lb_amt, lt, lq = _place_limit(lt, lq, pc, tick_l[i], h_lim)
            if lb_side != 0:
                lb_f = 0.0
                lb_hw = lb_pu if lb_side == 1 else lb_pl
                last_lim = t_now
                n_repl += 1

        # ---- end-of-candle: base OOR tracking + guarded recenter ----
        if L > 0.0:
            if pa <= pc <= pb:
                oor_since = None
                tir += 1
            else:
                if oor_since is None:
                    oor_since = t_now
                if (t_now - oor_since) >= OOR_DWELL and (t_now - last_rec) >= BASE_RECENTER_MIN_INTERVAL:
                    dev = pc / twap_l[i] - 1.0
                    if -TWAP_SANITY <= dev <= TWAP_SANITY:
                        # withdraw base into reserve (one-sided since OOR)
                        if pc <= pa:
                            bt += L * (1.0 / sa - isb)
                        elif pc >= pb:
                            bq += L * (sb - sa)
                        else:
                            bt += L * (1.0 / sp - isb)
                            bq += L * (sp - sa)
                        L = 0.0
                        # new band centered at spot, width from CURRENT vol
                        tt = tick_l[i]
                        half = BASE_HALF_TICKS * width_mult(sigpost[i])
                        ba_t = max(tt - half, -TICK_BOUND)
                        bb_t = min(tt + half, TICK_BOUND)
                        pa = math.exp(ba_t * LN_T); pb = math.exp(bb_t * LN_T)
                        sa = math.sqrt(pa); sb = math.sqrt(pb); isb = 1.0 / sb
                        # NAV now (for the 3%-of-NAV IL cap)
                        lim_val = lt * pc + lq
                        if lb_side == 1:
                            lim_val += lb_amt * (1.0 - lb_f)
                        elif lb_side == -1:
                            lim_val += lb_amt * (1.0 - lb_f) * pc
                        nav_now = bt * pc + bq + lim_val + fees_q
                        # rebalance toward the new band's ratio, capped, 1% slippage penalty
                        isp = 1.0 / sp
                        d_t = isp - isb      # token per unit L
                        d_q = sp - sa        # quote per unit L
                        v_tok = bt * pc
                        v_all = v_tok + bq
                        theta = (pc * d_t) / (pc * d_t + d_q) if (pc * d_t + d_q) > 0.0 else 0.5
                        diff = theta * v_all - v_tok
                        cap = MAX_IL_FRAC * nav_now
                        if diff > 0.0:  # buy token with quote
                            x = diff if diff < cap else cap
                            if x > bq:
                                x = bq
                            if x > 0.0:
                                bq -= x
                                bt += x * (1.0 - RECENTER_SLIP) / pc
                                realized_loss += x * RECENTER_SLIP
                        elif diff < 0.0:  # sell token for quote
                            x = -diff if -diff < cap else cap
                            if x > v_tok:
                                x = v_tok
                            if x > 0.0:
                                bt -= x / pc
                                bq += x * (1.0 - RECENTER_SLIP)
                                realized_loss += x * RECENTER_SLIP
                        # deploy (getLiquidityForAmounts: min of the two sides; leftover stays idle)
                        l_t = bt / d_t if d_t > 1e-18 else INF
                        l_q = bq / d_q if d_q > 1e-18 else INF
                        L = l_t if l_t < l_q else l_q
                        if L == INF or L < 0.0:
                            L = 0.0
                        if L > 0.0:
                            bt -= L * d_t
                            bq -= L * d_q
                        n_rec += 1
                        last_rec = t_now
                        oor_since = None
                        tir += 1  # recentered band contains spot

        # ---- NAV + drawdown + balance floor ----
        if L > 0.0:
            if pc <= pa:
                bval = L * (1.0 / sa - isb) * pc
            elif pc >= pb:
                bval = L * (sb - sa)
            else:
                bval = L * ((1.0 / sp - isb) * pc + (sp - sa))
        else:
            bval = 0.0
        lim_val = lt * pc + lq
        if lb_side == 1:
            lim_val += lb_amt * (1.0 - lb_f)
        elif lb_side == -1:
            lim_val += lb_amt * (1.0 - lb_f) * pc
        nav = bval + bt * pc + bq + lim_val + fees_q
        if nav > peak:
            peak = nav
        else:
            dd = (peak - nav) / peak
            if dd > mdd:
                mdd = dd
        b = bt if bt < bq else bq
        if lt < b:
            b = lt
        if lq < b:
            b = lq
        if b < min_bal:
            min_bal = b
        nav_prev = nav  # fee base for the NEXT candle (turnover model)

    res = {
        "final_nav": nav,
        "ret_pct": (nav - 1.0) * 100.0,
        "fees": fees_q,
        "realized_recenter_loss": realized_loss,
        "base_tir_pct": 100.0 * tir / n,
        "n_base_recenters": n_rec,
        "n_limit_fills": n_fills,
        "n_limit_replacements": n_repl,
        "max_dd_pct": mdd * 100.0,
        "min_balance": min_bal,
    }
    if debug:
        pc = c_l[-1]
        if L > 0.0:
            if pc <= pa:
                b_tok, b_quo = L * (1.0 / sa - isb), 0.0
            elif pc >= pb:
                b_tok, b_quo = 0.0, L * (sb - sa)
            else:
                b_tok, b_quo = L * (1.0 / sp_l[-1] - isb), L * (sp_l[-1] - sa)
        else:
            b_tok = b_quo = 0.0
        res["_debug"] = {
            "L": L, "pa": pa, "pb": pb,
            "base_token_in_band": b_tok, "base_quote_in_band": b_quo,
            "bt": bt, "bq": bq, "lt": lt, "lq": lq,
            "lb_side": lb_side, "lb_pl": lb_pl, "lb_pu": lb_pu,
            "lb_amt": lb_amt, "lb_f": lb_f,
        }
    return res


# ---------------------------------------------------------------------------
# Benchmarks (same candle series, same fee model where applicable)
# ---------------------------------------------------------------------------
def benchmarks(P, turnover):
    p0 = P["p0"]
    c = P["c"]
    fee = P["fee"]
    shape = P["volshape"]
    n = P["n"]
    hodl_ret = (0.5 + 0.5 * c[-1] / p0 - 1.0) * 100.0
    # full-range v2 LP: value = sqrt(p/p0) (50/50 at p0); fees at overlap=1, turnover model
    peak = 1.0
    mdd = 0.0
    nav = 1.0
    fees = 0.0
    for i in range(n):
        pv = math.sqrt(c[i] / p0)
        fees += fee[i] * turnover * (pv + fees) * shape[i]
        nav = pv + fees
        if nav > peak:
            peak = nav
        else:
            dd = (peak - nav) / peak
            if dd > mdd:
                mdd = dd
    return {
        "hodl_5050_ret_pct": hodl_ret,
        "quote_ret_pct": 0.0,
        "v2_full_range": {
            "final_nav": nav,
            "ret_pct": (nav - 1.0) * 100.0,
            "fees": fees,
            "max_dd_pct": mdd * 100.0,
        },
    }


# ---------------------------------------------------------------------------
# Grid
# ---------------------------------------------------------------------------
def run_grid(P, weights_pct, widths_pct, turnovers):
    t_start = time.time()
    grid = []
    bench_by_share = {}
    for tv in turnovers:
        bench = benchmarks(P, tv)
        base_only = run_strategy(P, 0.0, widths_pct[0], tv)
        bench["base_only"] = {k: base_only[k] for k in
                              ("final_nav", "ret_pct", "fees", "realized_recenter_loss",
                               "base_tir_pct", "n_base_recenters", "max_dd_pct")}
        bench_by_share[str(tv)] = bench
        h_ret = bench["hodl_5050_ret_pct"]
        v2_ret = bench["v2_full_range"]["ret_pct"]
        b0_ret = base_only["ret_pct"]
        for w_pct in weights_pct:
            for wd in widths_pct:
                if w_pct == 0.0:
                    m = dict(base_only)  # width irrelevant at w=0
                else:
                    m = run_strategy(P, w_pct / 100.0, wd, tv)
                row = {
                    "w_pct": w_pct, "width_pct": wd, "turnover_per_day": tv,
                    "final_nav": m["final_nav"], "ret_pct": m["ret_pct"],
                    "vs_hodl_pp": m["ret_pct"] - h_ret,
                    "vs_quote_pp": m["ret_pct"] - 0.0,
                    "vs_v2lp_pp": m["ret_pct"] - v2_ret,
                    "vs_base_only_pp": m["ret_pct"] - b0_ret,
                    "fees": m["fees"],
                    "realized_recenter_loss": m["realized_recenter_loss"],
                    "base_tir_pct": m["base_tir_pct"],
                    "n_base_recenters": m["n_base_recenters"],
                    "n_limit_fills": m["n_limit_fills"],
                    "n_limit_replacements": m["n_limit_replacements"],
                    "max_dd_pct": m["max_dd_pct"],
                    "min_balance": m["min_balance"],
                }
                grid.append(row)
    return grid, bench_by_share, time.time() - t_start


# ---------------------------------------------------------------------------
# Sanity suite
# ---------------------------------------------------------------------------
def sanity_suite():
    checks = []

    def add(name, ok, detail):
        checks.append({"check": name, "pass": bool(ok), "detail": detail})

    # 1) flat price: 0 recenters, 0 realized loss; fees follow the TURNOVER model
    #    (fee_floor x turnover x days, compounding on NAV) and scale ~linearly with turnover.
    flat1 = [(1000 + 300 * i, 1.0, 1.0, 1.0, 1.0, 1.0) for i in range(400)]
    P1 = precompute(flat1)
    days = P1["total_days"]
    m1 = run_strategy(P1, 0.20, 5.0, 1.0)   # turnover 1x/day
    m2 = run_strategy(P1, 0.20, 5.0, 2.0)   # turnover 2x/day
    exp1 = MEME_FEE_FLOOR * 1.0 * days  # linear accrual on principal (no fee-on-fee)
    ok = (m1["n_base_recenters"] == 0 and m1["realized_recenter_loss"] == 0.0
          and abs(m1["fees"] - exp1) / exp1 < 0.02
          and abs(m2["fees"] / m1["fees"] - 2.0) < 0.05
          and m1["n_limit_fills"] == 0)
    add("flat-price: 0 recenters, 0 realized loss; fees ~= floor*turnover*days (linear, no fee-on-fee), ~2x at 2x turnover",
        ok,
        "recenters=%d loss=%.3e fees=%.6f (exp %.6f) fees@2xTurnover/fees=%.4f fills=%d days=%.3f"
        % (m1["n_base_recenters"], m1["realized_recenter_loss"], m1["fees"], exp1,
           m2["fees"] / m1["fees"], m1["n_limit_fills"], days))

    # 2) one-way 10x moonshot in 100 candles: base ends one-sided, no crash/negative balances,
    #    TWAP sanity gate blocks trend-chasing recenters
    moon = []
    prev = 1.0
    for i in range(100):
        c = 10.0 ** ((i + 1) / 100.0)
        moon.append((1000 + 300 * i, prev, c, prev, c, 1.0))
        prev = c
    mm = run_strategy(precompute(moon), 0.20, 5.0, 2.0, debug=True)
    dbg = mm["_debug"]
    one_sided = dbg["base_token_in_band"] < 1e-9 and moon[-1][4] >= dbg["pb"]
    ok = (mm["min_balance"] >= -1e-9 and mm["final_nav"] > 0.0
          and math.isfinite(mm["final_nav"]) and one_sided and mm["n_base_recenters"] == 0)
    add("10x moonshot: base ends one-sided (all quote), no negative balances, NAV finite>0, "
        "TWAP sanity blocks trend-chasing recenter",
        ok,
        "final_nav=%.4f min_bal=%.2e base_token=%.2e price_end=%.3f > band_hi=%.3f recenters=%d"
        % (mm["final_nav"], mm["min_balance"], dbg["base_token_in_band"], moon[-1][4], dbg["pb"],
           mm["n_base_recenters"]))

    # 3) limit-fill value conservation at the band's geometric-mean price
    cons = [(1000, 1.0, 1.0, 1.0, 1.0, 0.0),
            (1300, 1.0, 1.0, 0.85, 0.85, 0.0)]
    mc = run_strategy(precompute(cons), 0.50, 10.0, 0.0, debug=True)
    d = mc["_debug"]
    pl = math.exp(-math.log1p(0.10))  # band [1/1.1, 1.0]
    gm = math.sqrt(pl * 1.0)
    err = abs(d["lt"] * gm - 0.50)
    ok = (mc["n_limit_fills"] == 1 and d["lb_f"] >= 1.0 - 1e-12 and err < 1e-12)
    add("limit-fill value conservation: 0.5 quote -> token at gm=sqrt(pl*pu); value at gm unchanged",
        ok,
        "fills=%d fill_frac=%.6f token_out=%.9f value_at_gm=%.12f (target 0.5, |err|=%.2e)"
        % (mc["n_limit_fills"], d["lb_f"], d["lt"], d["lt"] * gm, err))

    # 4) wider vol -> wider base (EWMA -> sigma -> width multiplier, end-to-end)
    P_lo = precompute(gen_gbm(50, 0, 3000, seed=7))
    P_hi = precompute(gen_gbm(250, 0, 3000, seed=7))
    mult_lo = sum(width_mult(s) for s in P_lo["sig_post"]) / 3000.0
    mult_hi = sum(width_mult(s) for s in P_hi["sig_post"]) / 3000.0
    fee_lo = sum(P_lo["fee"]) / 3000.0
    fee_hi = sum(P_hi["fee"]) / 3000.0
    r_lo = run_strategy(P_lo, 0.0, 5.0, 2.0)
    r_hi = run_strategy(P_hi, 0.0, 5.0, 2.0)
    ok = (mult_hi > mult_lo and fee_hi > fee_lo
          and math.isfinite(r_lo["final_nav"]) and math.isfinite(r_hi["final_nav"]))
    add("wider vol -> wider base width multiplier (and higher dynamic fee)",
        ok,
        "mean_mult: 50%%vol=%.3fx vs 250%%vol=%.3fx; mean_fee: %.4f%% vs %.4f%%; "
        "recenters lo=%d hi=%d"
        % (mult_lo, mult_hi, fee_lo * 100, fee_hi * 100,
           r_lo["n_base_recenters"], r_hi["n_base_recenters"]))

    # 5) end-to-end synthetic GBM mini-grid: finite outputs, engine completes
    P5 = precompute(gen_gbm(150, 0, 4000, seed=42))
    t0 = time.time()
    grid, bench, _ = run_grid(P5, [0.0, 20.0], [5.0], [2.0])
    el = time.time() - t0
    finite = all(math.isfinite(row["final_nav"]) and row["min_balance"] >= -1e-9 for row in grid)
    ok = finite and len(grid) == 2
    add("synthetic GBM (150% vol, 4000 candles) mini-grid: completes, finite NAV, no negative balances",
        ok,
        "rows=%d navs=%s hodl=%.2f%% elapsed=%.2fs"
        % (len(grid), ["%.4f" % r["final_nav"] for r in grid],
           bench["2.0"]["hodl_5050_ret_pct"], el))

    return all(c["pass"] for c in checks), checks


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _floats(s):
    return [float(x) for x in s.split(",") if x.strip() != ""]


def main():
    ap = argparse.ArgumentParser(description="FERA base+limit vault strategy backtest simulator")
    ap.add_argument("--data", help="candles JSON: {\"candles\":[[ts,o,h,l,c,volQuote],...]}")
    ap.add_argument("--out", help="results JSON output path")
    ap.add_argument("--weights", default="0,5,10,15,20,25,30,40,50,60,75",
                    help="limit weights w in %% of tranche capital")
    ap.add_argument("--widths", default="1,2,5,10,15", help="limit band widths in %%")
    ap.add_argument("--turnovers", default="0.5,2,5",
                    help="pool daily volume as a multiple of pool TVL (fee model v2)")
    ap.add_argument("--start-ts", type=int, default=None)
    ap.add_argument("--end-ts", type=int, default=None)
    ap.add_argument("--synthetic", default=None, help="gbm:<volPct>:<driftPct>:<candles>")
    ap.add_argument("--seed", type=int, default=42, help="synthetic GBM seed")
    ap.add_argument("--sanity", action="store_true", help="run the sanity suite and exit")
    args = ap.parse_args()

    if args.sanity:
        ok, checks = sanity_suite()
        out = {"all_pass": ok, "checks": checks}
        print(json.dumps(out, indent=2))
        if args.out:
            with open(args.out, "w") as fh:
                json.dump(out, fh, indent=2)
        sys.exit(0 if ok else 1)

    if args.synthetic:
        parts = args.synthetic.split(":")
        if len(parts) != 4 or parts[0] != "gbm":
            raise SystemExit("--synthetic must be gbm:<volPct>:<driftPct>:<candles>")
        candles = gen_gbm(float(parts[1]), float(parts[2]), int(parts[3]), seed=args.seed)
        source = args.synthetic + " (seed=%d)" % args.seed
    elif args.data:
        candles = load_candles(args.data, args.start_ts, args.end_ts)
        source = args.data
    else:
        raise SystemExit("need --data or --synthetic (or --sanity)")

    if not args.out:
        raise SystemExit("need --out for a grid run")

    weights = _floats(args.weights)
    widths = _floats(args.widths)
    turnovers = _floats(args.turnovers)

    t0 = time.time()
    P = precompute(candles)
    grid, bench, grid_sec = run_grid(P, weights, widths, turnovers)
    total_sec = time.time() - t0

    def _san(x):  # JSON-safe
        if isinstance(x, float) and not math.isfinite(x):
            return None
        return x

    for row in grid:
        for k in row:
            row[k] = _san(row[k])

    result = {
        "meta": {
            "sim_version": SIM_VERSION,
            "source": source,
            "n_candles": P["n"],
            "ts_range": [P["ts"][0], P["ts"][-1]],
            "candle_sec_median": P["dt_med"],
            "p0": P["p0"],
            "p_end": P["c"][-1],
            "weights_pct": weights,
            "widths_pct": widths,
            "turnovers_per_day": turnovers,
            "grid_runs": len(grid),
            "elapsed_sec": round(total_sec, 3),
            "constants": {
                "ACTIVE_BASE_HALF_TICKS": 2624, "fee_floor_pips": 3400, "fee_ceil_pips": 30000,
                "fee_slope_pips_per_tick": 200, "sigma0_ticks": 4,
                "width_mult_range_x": [0.5, 25.0], "width_mult_slope_bps_per_tick": 300,
                "min_limit_interval_sec": 1800, "oor_dwell_sec": 3600,
                "base_recenter_min_interval_sec": 21600, "il_cap_bps": 300,
                "recenter_slippage_bps": 100, "twap_window_sec": 1800, "twap_sanity_bps": 500,
            },
        },
        "benchmarks_by_turnover": bench,
        "grid": grid,
    }
    with open(args.out, "w") as fh:
        json.dump(result, fh, indent=1)
    print("wrote %s: %d grid rows over %d candles in %.1fs (grid loop %.1fs)"
          % (args.out, len(grid), P["n"], total_sec, grid_sec))


if __name__ == "__main__":
    main()
