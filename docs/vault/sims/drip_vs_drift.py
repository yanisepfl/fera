#!/usr/bin/env python3
"""
FERA vault review — drip recentering vs memecoin drift (Agent V, docs/vault/).

Question (VAULT_ARCHITECTURE.md §2.2): is drip-only recentering (principal-passive,
fee-active) sufficient for MEME pools, or does the vault need guarded principal recenters?

Compares four $-identical liquidity structures on the same exogenous price/volume series:
  FULL_V1        : v1 baseline — 100% full-range, fees compounded daily full-range. 10% perf fee.
  LADDER_DRIP    : v2 proposal — core ±30% (30%) / mid ±100% (40%) / tail full (30%);
                   principal never moved; 90% fee income dripped daily into NEW ±30%
                   core bands at spot (never recycled). 10% perf fee.
  LADDER_RECENTER: same ladder, but core+mid principal is closed & re-minted at spot after
                   price sits outside the core band for HYST_H hours (realized IL + swap/MEV
                   cost on the turned-over inventory). Fees dripped as in LADDER_DRIP.
  DIRECT_CENTERED: competing sophisticated direct LP (open liquidity, D-11): $250k always-
                   centered ±30%, recenters every 12h at swap cost, keeps 100% of fees.

Pool composition per instance: strategy under test ($1M) + DIRECT_CENTERED ($250k)
+ passive vanilla full-range ($250k). Volume is exogenous and identical across instances
(conservative: ignores that deeper quotes attract more routed volume, which favors the
deeper strategy further).

Metrics: at-spot depth multiple vs FULL_V1 (v3 L units), fee capture share, LP PnL vs
50/50 HODL (post perf fee), band count (withdraw-gas proxy), recenter costs.

Scenarios: (A) GBM+jumps memecoin chop, 90d, N Monte-Carlo paths;
           (B) 3x run-up over 30d then 60d sideways;
           (C) -70% grind-down over 90d.

Also prints a JIT expected-value table vs min-hold length (supports review point (d)).

Pure python3 + numpy. Deterministic (seed 42). Runtime target < 90s.
"""

import numpy as np

HOURS = 24
DT_PER_DAY = 24          # hourly steps
DAYS = 90
T = DAYS * DT_PER_DAY

# ---------------- market / strategy parameters ----------------
P0 = 1.0
TVL = 1_000_000.0        # vault strategy under test
DIRECT_TVL = 250_000.0   # always-centered direct LP competitor
VANILLA_TVL = 250_000.0  # passive full-range third party

BASE_DAILY_VOL = 600_000.0   # $ routed volume / day at calm
FEE_FLOOR, FEE_CEIL = 0.003, 0.03  # MEME regime (PARAMS frozen floor/ceiling)
SIGMA_REF_DAILY = 0.03       # daily vol at which fee = floor
EWMA_HALFLIFE_H = 12.0

PERF_FEE = 0.10

CORE_K, MID_K = 1.3, 2.0     # ±30% / ±100% (geometric)
W_CORE, W_MID, W_TAIL = 0.30, 0.40, 0.30

DRIP_EVERY_H = 24
DRIP_MIN = 1_000.0
DRIP_DEPLOY_COST = 0.0035    # swap-assist on ~half the dripped amount

RECENTER_HYST_H = 12         # hours continuously outside core band before recenter
REBAL_SWAP_FRAC = 0.45       # fraction of closed value swapped to rebalance 50/50
REBAL_COST_RATE = 0.007      # fee 30bp + slippage 20bp + MEV 20bp on swapped notional

DIRECT_RECENTER_H = 12

RNG_SEED = 42
N_MC = 100

# ---------------- v3 math ----------------

def liq_for_value(value, p_mint, pa, pb):
    """v3 liquidity L for a position worth `value` (quote terms) minted at p_mint in [pa,pb]."""
    sp, sa, sb = np.sqrt(p_mint), np.sqrt(pa), np.sqrt(pb)
    if p_mint <= pa:      # all token0
        denom = (1.0 / sa - 1.0 / sb) * p_mint
    elif p_mint >= pb:    # all token1
        denom = sb - sa
    else:
        denom = 2.0 * sp - p_mint / sb - sa
    return value / denom

def band_value(L, p, pa, pb):
    """Mark-to-market value (quote terms) of L in [pa,pb] at price p."""
    sp, sa, sb = np.sqrt(p), np.sqrt(pa), np.sqrt(pb)
    if p <= pa:
        return L * (1.0 / sa - 1.0 / sb) * p
    if p >= pb:
        return L * (sb - sa)
    return L * (2.0 * sp - p / sb - sa)

FULL_PA, FULL_PB = 1e-12, 1e12   # "full range" numeric stand-in

class Band:
    __slots__ = ("pa", "pb", "L")
    def __init__(self, pa, pb, L):
        self.pa, self.pb, self.L = pa, pb, L
    def in_range(self, p):
        return self.pa < p < self.pb
    def value(self, p):
        return band_value(self.L, p, self.pa, self.pb)

def mint_band(value, p, k):
    return Band(p / k, p * k, liq_for_value(value, p, p / k, p * k))

def mint_full(value, p):
    return Band(FULL_PA, FULL_PB, liq_for_value(value, p, FULL_PA, FULL_PB))

# ---------------- price paths ----------------

def path_gbm_jumps(rng, days=DAYS, sigma_d=0.08, jump_per_day=0.3, jump_scale=0.30,
                   drift_d=0.0, down_only=False):
    n = days * DT_PER_DAY
    sig_h = sigma_d / np.sqrt(DT_PER_DAY)
    mu_h = drift_d / DT_PER_DAY
    r = rng.normal(mu_h - 0.5 * sig_h ** 2, sig_h, n)
    jmask = rng.random(n) < (jump_per_day / DT_PER_DAY)
    jsize = rng.normal(0.0, jump_scale, n)
    if down_only:
        jsize = -np.abs(jsize)
    r = r + jmask * jsize
    p = P0 * np.exp(np.cumsum(r))
    return p, r, jmask

def path_runup(rng):
    """3x over 30 days, then 60 days sideways chop."""
    n1, n2 = 30 * DT_PER_DAY, 60 * DT_PER_DAY
    sig1 = 0.04 / np.sqrt(DT_PER_DAY)
    sig2 = 0.06 / np.sqrt(DT_PER_DAY)
    r1 = rng.normal(np.log(3.0) / n1, sig1, n1)
    r2 = rng.normal(0.0, sig2, n2)
    r = np.concatenate([r1, r2])
    jmask = rng.random(n1 + n2) < (0.15 / DT_PER_DAY)
    r = r + jmask * rng.normal(0, 0.2, n1 + n2)
    return P0 * np.exp(np.cumsum(r)), r, jmask

def path_grind_down(rng):
    """-70% over 90 days with down-biased jumps."""
    return path_gbm_jumps(rng, sigma_d=0.07, jump_per_day=0.2, jump_scale=0.25,
                          drift_d=np.log(0.30) / DAYS, down_only=True)

# ---------------- fee / volume series ----------------

def fee_volume_series(r, jmask):
    lam = 0.5 ** (1.0 / EWMA_HALFLIFE_H)
    var = (0.08 / np.sqrt(DT_PER_DAY)) ** 2
    n = len(r)
    fee = np.empty(n)
    vol = np.empty(n)
    exp_abs = 0.8 * np.sqrt(var)
    base_h = BASE_DAILY_VOL / DT_PER_DAY
    for t in range(n):
        var = lam * var + (1 - lam) * r[t] ** 2
        sig_d = np.sqrt(var * DT_PER_DAY)
        fee[t] = min(max(FEE_FLOOR * (sig_d / SIGMA_REF_DAILY), FEE_FLOOR), FEE_CEIL)
        m = 0.3 + 0.7 * min(abs(r[t]) / exp_abs, 8.0)
        if jmask[t]:
            m *= 4.0
        vol[t] = base_h * m
    return fee, vol

# ---------------- strategies ----------------

class Strategy:
    def __init__(self, name, p0):
        self.name = name
        self.cash = 0.0            # undeployed fee income (LP 90% share), $ value
        self.fees_gross = 0.0      # fees earned by positions, pre perf-fee
        self.perf_paid = 0.0
        self.costs = 0.0           # swap/MEV/deploy costs paid
        self.recenters = 0
        self.bands = []
        self.build(p0)

    def build(self, p0):
        raise NotImplementedError

    def L_at(self, p):
        return sum(b.L for b in self.bands if b.in_range(p))

    def credit_fees(self, amt):
        self.fees_gross += amt
        skim = PERF_FEE * amt
        self.perf_paid += skim
        self.cash += amt - skim

    def total_value(self, p):
        return sum(b.value(p) for b in self.bands) + self.cash

    def step(self, t, p):
        pass

class FullV1(Strategy):
    def build(self, p0):
        self.bands = [mint_full(TVL, p0)]
    def step(self, t, p):
        if t % DRIP_EVERY_H == 0 and self.cash >= DRIP_MIN:  # daily compound, kind=4
            amt = self.cash * (1 - DRIP_DEPLOY_COST)
            self.costs += self.cash - amt
            self.bands[0].L += liq_for_value(amt, p, FULL_PA, FULL_PB)
            self.cash = 0.0

class LadderDrip(Strategy):
    def build(self, p0):
        self.bands = [mint_band(W_CORE * TVL, p0, CORE_K),
                      mint_band(W_MID * TVL, p0, MID_K),
                      mint_full(W_TAIL * TVL, p0)]
    def step(self, t, p):
        if t % DRIP_EVERY_H == 0 and self.cash >= DRIP_MIN:  # kind=5 dripDeploy
            amt = self.cash * (1 - DRIP_DEPLOY_COST)
            self.costs += self.cash - amt
            self.bands.append(mint_band(amt, p, CORE_K))
            self.cash = 0.0

class LadderRecenter(LadderDrip):
    def build(self, p0):
        super().build(p0)
        self.core, self.mid = self.bands[0], self.bands[1]
        self.oor_hours = 0
    def step(self, t, p):
        super().step(t, p)
        if not self.core.in_range(p):
            self.oor_hours += 1
        else:
            self.oor_hours = 0
        if self.oor_hours >= RECENTER_HYST_H:
            v = self.core.value(p) + self.mid.value(p)       # realized IL is embedded here
            cost = REBAL_SWAP_FRAC * v * REBAL_COST_RATE
            self.costs += cost
            v -= cost
            wc = W_CORE / (W_CORE + W_MID)
            self.bands.remove(self.core)
            self.bands.remove(self.mid)
            self.core = mint_band(wc * v, p, CORE_K)
            self.mid = mint_band((1 - wc) * v, p, MID_K)
            self.bands = [self.core, self.mid] + self.bands
            self.recenters += 1
            self.oor_hours = 0

class LadderGuarded(LadderDrip):
    """Drip default + RARE guarded principal recenter: only fires when the vault's
    at-spot depth has been worse than the v1 full-range baseline (depth multiple < 1)
    for GUARD_PERSIST_H consecutive hours, at most once per GUARD_MIN_INTERVAL_D days.
    Encodes 'recenter only when the ladder has lost its reason to exist'."""
    GUARD_PERSIST_H = 24
    GUARD_MIN_INTERVAL_D = 7

    def build(self, p0):
        super().build(p0)
        self.core, self.mid = self.bands[0], self.bands[1]
        self.L_ref = liq_for_value(TVL, p0, FULL_PA, FULL_PB)
        self.weak_hours = 0
        self.last_recenter = -10**9

    def step(self, t, p):
        super().step(t, p)
        if self.L_at(p) < self.L_ref:
            self.weak_hours += 1
        else:
            self.weak_hours = 0
        if (self.weak_hours >= self.GUARD_PERSIST_H
                and t - self.last_recenter >= self.GUARD_MIN_INTERVAL_D * DT_PER_DAY):
            v = self.core.value(p) + self.mid.value(p)
            cost = REBAL_SWAP_FRAC * v * REBAL_COST_RATE
            self.costs += cost
            v -= cost
            wc = W_CORE / (W_CORE + W_MID)
            self.bands.remove(self.core)
            self.bands.remove(self.mid)
            self.core = mint_band(wc * v, p, CORE_K)
            self.mid = mint_band((1 - wc) * v, p, MID_K)
            self.bands = [self.core, self.mid] + self.bands
            self.recenters += 1
            self.last_recenter = t
            self.weak_hours = 0

class DirectCentered(Strategy):
    """$250k always-centered ±30% direct LP; recenters every 12h; no perf fee."""
    def build(self, p0):
        self.bands = [mint_band(DIRECT_TVL, p0, CORE_K)]
    def credit_fees(self, amt):
        self.fees_gross += amt
        self.cash += amt            # keeps 100%
    def step(self, t, p):
        if t % DIRECT_RECENTER_H == 0 and t > 0:
            b = self.bands[0]
            if not (0.995 * p < np.sqrt(b.pa * b.pb) < 1.005 * p):
                v = b.value(p) + self.cash
                cost = REBAL_SWAP_FRAC * b.value(p) * REBAL_COST_RATE
                self.costs += cost
                self.bands = [mint_band(v - cost, p, CORE_K)]
                self.cash = 0.0
                self.recenters += 1

# ---------------- simulation ----------------

def run_instance(vault_cls, prices, fee, vol):
    p0 = P0
    vault = vault_cls(vault_cls.__name__, p0)
    direct = DirectCentered("direct", p0)
    vanilla = mint_full(VANILLA_TVL, p0)
    depth_mult = np.empty(len(prices))
    L_full_ref = liq_for_value(TVL, p0, FULL_PA, FULL_PB)  # constant-L v1 yardstick
    pool_fees = 0.0
    for t, p in enumerate(prices):
        Lv, Ld = vault.L_at(p), direct.L_at(p)
        Ltot = Lv + Ld + vanilla.L
        f = vol[t] * fee[t]
        pool_fees += f
        if Ltot > 0:
            vault.credit_fees(f * Lv / Ltot)
            direct.credit_fees(f * Ld / Ltot)
        vault.step(t, p)
        direct.step(t, p)
        depth_mult[t] = vault.L_at(p) / L_full_ref
    pT = prices[-1]
    hodl = TVL / 2 + (TVL / 2) * pT / P0
    return dict(
        name=vault.name,
        avg_depth=float(np.mean(depth_mult)),
        min_depth=float(np.min(depth_mult)),
        end_depth=float(depth_mult[-1]),
        frac_below_v1=float(np.mean(depth_mult < 1.0)),
        fees=vault.fees_gross,
        fee_share=vault.fees_gross / pool_fees,
        direct_fees=direct.fees_gross,
        cap_ratio=(vault.fees_gross / TVL) / (direct.fees_gross / DIRECT_TVL)
                  if direct.fees_gross > 0 else float("nan"),
        value=vault.total_value(pT),
        pnl=vault.total_value(pT) - TVL,
        pnl_vs_hodl=(vault.total_value(pT) - hodl) / TVL,
        bands=len(vault.bands),
        recenters=vault.recenters,
        costs=vault.costs,
        perf=vault.perf_paid,
    )

STRATS = [FullV1, LadderDrip, LadderRecenter, LadderGuarded]

def run_scenario(label, path_fn, n_paths):
    rng = np.random.default_rng(RNG_SEED)
    acc = {s.__name__: [] for s in STRATS}
    for _ in range(n_paths):
        prices, r, jmask = path_fn(rng)
        fee, vol = fee_volume_series(r, jmask)
        for s in STRATS:
            acc[s.__name__].append(run_instance(s, prices, fee, vol))
    print(f"\n=== Scenario {label} ({n_paths} path{'s' if n_paths>1 else ''}) ===")
    keys = ["avg_depth", "min_depth", "end_depth", "frac_below_v1", "fee_share",
            "cap_ratio", "pnl", "pnl_vs_hodl", "bands", "recenters", "costs", "perf"]
    hdr = f"{'strategy':<16}" + "".join(f"{k:>14}" for k in keys)
    print(hdr); print("-" * len(hdr))
    for name, rows in acc.items():
        med = {k: float(np.median([row[k] for row in rows])) for k in keys}
        p10 = {k: float(np.percentile([row[k] for row in rows], 10)) for k in keys}
        p90 = {k: float(np.percentile([row[k] for row in rows], 90)) for k in keys}
        def fmt(k, d):
            v = d[k]
            if k in ("pnl", "costs", "perf"):
                return f"{v:>14,.0f}"
            if k in ("bands", "recenters"):
                return f"{v:>14.0f}"
            return f"{v:>14.3f}"
        print(f"{name:<16}" + "".join(fmt(k, med) for k in keys))
        if n_paths > 1:
            print(f"{'  p10':<16}" + "".join(fmt(k, p10) for k in keys))
            print(f"{'  p90':<16}" + "".join(fmt(k, p90) for k in keys))
    return acc

# ---------------- JIT expected-value vs min-hold ----------------

def jit_table():
    """EV of a JIT play around a $100k memecoin dump at 3% fee, vs enforced hold time.

    Bot mints L_mult x the pool's at-spot depth in a tight band just before the dump,
    captures fee share L_jit/(L_jit+L_pool), inherits ~the swap notional as inventory,
    then must hold `H` before removal. Post-dump toxic drift mu_d (informed flow) and
    vol sigma_h; memecoins are largely unhedgeable (no perp), so inventory risk is real.
    EV = feeCapture - |inventory| * mu_d * H - 0.5 * |inventory| * sigma_h * sqrt(H).
    (0.5 = risk charge on 1-sigma move; conservative-ish.)"""
    swap, fee, L_mult = 100_000.0, 0.03, 3.0
    mu_d_per_h, sig_per_sqrt_h = 0.02, 0.03
    capture = fee * swap * (L_mult / (1 + L_mult))
    print("\n=== JIT EV vs enforced min-hold (dump $100k, fee 3%, bot 3x pool depth) ===")
    print(f"fee captured by JIT position: ${capture:,.0f}")
    print(f"{'min-hold':>10} {'drift cost':>12} {'risk charge':>12} {'EV':>12}")
    for h_s in [0.1, 1, 10, 60, 300, 900, 1800, 3600]:
        h = h_s / 3600.0
        drift = swap * mu_d_per_h * h
        risk = 0.5 * swap * sig_per_sqrt_h * np.sqrt(h)
        ev = capture - drift - risk
        print(f"{h_s:>9.1f}s {drift:>12,.0f} {risk:>12,.0f} {ev:>12,.0f}")
    print("(100ms blocks: a '1-block delay' = 0.1s -> EV unchanged; deterrence needs minutes.)")

# ---------------- main ----------------

if __name__ == "__main__":
    np.set_printoptions(suppress=True)
    print("FERA drip_vs_drift simulator — params:",
          f"TVL=${TVL:,.0f}, ladder {W_CORE}/{W_MID}/{W_TAIL} @ ±30/±100/full,",
          f"drip daily min ${DRIP_MIN:,.0f}, recenter hysteresis {RECENTER_HYST_H}h,",
          f"rebal cost {REBAL_COST_RATE:.1%} on {REBAL_SWAP_FRAC:.0%} of closed value,",
          f"fee in [{FEE_FLOOR:.1%},{FEE_CEIL:.1%}], base volume ${BASE_DAILY_VOL:,.0f}/d,",
          f"seed {RNG_SEED}")
    run_scenario("A: memecoin chop (GBM sigma 8%/d + jumps ±30%, 90d)", path_gbm_jumps, N_MC)
    run_scenario("B: 3x run-up 30d, then 60d sideways", path_runup, N_MC)
    run_scenario("C: grind-down to 0.3x over 90d", path_grind_down, N_MC)
    jit_table()
