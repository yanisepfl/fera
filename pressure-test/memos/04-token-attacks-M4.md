# Memo 04 — M4 Token/Emission Attacks

**Verdict: FAIL (preliminary).** The base wash-farming defense holds *only* under flat FERA
price and no boost. It **breaks** under (i) the 2x self-boost and (ii) FERA appreciation >39%
over the vest. The cheapest profitable attack has **cost/profit ≈ 0.5–5x — far under the 10x
bar** (mission rule: `<10x cost/profit is FAIL`). Harness: `harnesses/wash_bot.py`. All numbers
PRELIMINARY (PARAMS.md, PT-1). **This is the single biggest existential risk found this session.**

## 1. The core arithmetic (why wash-farming is *supposed* to be net-negative)

A self-dealing whale that both **trades** and **LPs** its own pool generates fee volume `F`.
The protocol skims the 10% perf fee (revenue `R = 0.10F`) and returns `0.90F` to LPs (itself).
So the **unavoidable cost of washing** is the perf fee `= 0.10F` (+ gas ≈ 0 under the holiday +
external arb leakage).

Maximum emission it can recapture, with the bound `E ≤ β·R = 0.8·0.10·F = 0.08F` and full
self-capture of **both** the 45% trader and 45% LP rebates:
```
take = (0.45 + 0.45) · 0.08F = 0.072F   (esFERA face value)
reward/cost = 0.072 / 0.10 = 0.72        -> NET-NEGATIVE, but margin only 28%
```
The defense is real but **thin**: it rests entirely on `β · perf_fee = 0.08 < perf_fee = 0.10`.

## 2. Where it breaks — `wash_bot.py` output

### [A] Self-dealing whole-pool whale, no boost
```
instant-exit (50% haircut)     reward/cost=0.36  net=-0.0640F   PASS
full vest, FERA flat (g=1.0)   reward/cost=0.72  net=-0.0280F   PASS
full vest, FERA +39% (g=1.39)  reward/cost=1.00  net=+0.0001F   break-even
full vest, FERA +100% (g=2.0)  reward/cost=1.44  net=+0.0440F   FAIL
```
**Break-even FERA appreciation = 0.10/0.072 = 1.39x over the 6-month vest.** A token that
appreciates >39% in six months — the *expected* case for a launching usage token in a bull
narrative — makes wash-farming **positive-carry**: it becomes a way to accumulate FERA below
market by paying only the perf fee. The haircut (instant exit) does *not* save you, because the
rational farmer simply **holds through the vest** and takes the price upside.

### [B] 2x self-boost, whale is a minority of protocol-wide fees (the real break)
```
theta=0.50  reward/cost=0.96  net=-0.00200F  no
theta=0.20  reward/cost=1.20  net=+0.00400F  PROFIT   cost/profit=5.00x  FAIL
theta=0.05  reward/cost=1.37  net=+0.00186F  PROFIT   cost/profit=2.69x  FAIL
theta=0.01  reward/cost=1.43  net=+0.00043F  PROFIT   cost/profit=2.35x  FAIL
```
The "up to 2x boost on your own emissions" (SHARED_CONTEXT §8) is the killer. Boost **reallocates
a fixed emission pool** (it must, or INV-7 breaks — PT-5), so a 2x-boosted self-dealer captures
`2θ/(1+θ)` of each rebate split instead of `θ` — **stealing honest users' emission share** while
paying perf fee only on its own small washed volume `θF`. As `θ→0` its recapture → `0.144/0.10 =
1.44x` (profitable). **Break-even appreciation with 2x boost drops to 0.10/0.144 = 0.69x — i.e.
profitable even if FERA *falls* up to 31% over the vest.** This is a subsidized FERA-accumulation
machine funded by honest LPs and traders.

### [C] Cheapest profitable attack
```
theta=0.01, boost=2.0, g=2.0  ->  reward/cost=2.85   cost/profit=0.54x
```
**cost/profit ≈ 0.5x ≪ 10x → FAIL.** The attacker recovers ~2.85x their cost.

## 3. Other emission vectors (severity-ranked)

1. **Boost concentration (CRITICAL, above, PT-2).** Cheapest and worst. The multiplier turns
   the flywheel into an extraction pump. **Fix mandatory before emissions param freeze.**
2. **FERA TWAP suppression during the snapshot (MEDIUM, PT-8).** Emitted FERA *count* =
   `β·revenue / FERA_TWAP`. Suppressing the TWAP during the snapshot window mints *more* FERA.
   It is USD-neutral *at the snapshot* (count × price = β·revenue), so it does **not** inflate
   emission value directly — but a farmer who suppresses the price, receives extra FERA, and
   **holds through recovery** earns the recovery on the extra tokens. Defense = the
   manipulation-capped TWAP window (per-block move cap + length). Cost to suppress the chain FERA
   price for a full window against arbitrage buying the dip, over ~100ms blocks, is large
   relative to the marginal emission gained (`≈ δ · 0.072F` for a δ suppression). Verdict:
   **bounded PASS if** PARAMS.md sets a real window + move cap; **confirm, don't assume**.
3. **Quality-score gaming (MEDIUM, PT-9).** Per-pool emission caps depend on an undefined "pool
   quality score" (§9 inputs). If it keys on raw volume/TVL, an attacker games it with the same
   wash flow to raise their pool's cap → more to farm (compounding attack #1). Defense: score
   must be built on **organic-classified** volume (memo 02) + unique-funded-wallet counts +
   cluster-collapsed identities, none of which the attacker controls. **Undefined = risk.**
4. **Staking-vs-LP equilibrium raid (INFO, PT-10).** sFERA gets 50% of revenue + boost; LPs get
   fees + 45% emissions. If staking yield ≫ LP yield, capital flees LP → TVL (our only cold
   start) collapses → routing dies (memo 03 depth dependency). A large actor can also stake
   heavily to dominate the revenue share *and* self-boost its own wash flow (compounds #1).
   Needs an explicit target sFERA-vs-LP yield ratio + stability argument.
5. **Wash to farm the *trader* rebate only (NON-ISSUE).** A pure trader (not the LP) recovers at
   most `0.45·0.08 = 0.036F` for a `1.0F` fee cost → ~28x underwater. Trivially net-negative.
   Confirmed by construction; not a threat.

## 4. Required fixes (adopt before emissions param freeze)

**PT-2 (mandatory, CRITICAL) — neuter self-boost:** boost must **not** apply to a staker's own
trader/LP emissions that derive from **self-generated or self-LP'd flow**. Options, cheapest to
build first:
- (a) **Rebate cap per trader:** trader rebate ≤ (fees paid) × k with small k — a rebate can
  never exceed a fraction of the fee that funded it, killing positive carry regardless of boost.
- (b) **Exclude self-matched volume:** flow where the swap counterparty liquidity is the same
  beneficial owner (Vault share owner == trader, via the cluster map from memo 02) earns no
  rebate. Requires identity clustering — reuse the census graph.
- (c) **Boost applies only to the *unboosted-share* baseline, capped so boosted take ≤ fee
  contribution** — i.e. boost can lift you toward, never past, your own fee contribution.
- (d) At minimum, **cap total self-take at the no-boost 0.072F** so appreciation is the only
  residual break, then address that via a longer vest / claw or a lower β.

**PT-5 (mandatory) — INV-7 ordering:** assert emission cap `min(cap, β·rev)` is enforced on the
**total after** boost weighting (share-in-a-fixed-pool), never boost-then-mint. Add invariant test.

**Appreciation residual (even after PT-2):** the no-boost break-even is 1.39x over the vest.
Consider one of: longer vest, β<0.8, or a rebate cap (option a) that makes the arithmetic
net-negative independent of price. **Flag: the "wash-farming is net-negative by arithmetic"
claim in SHARED_CONTEXT §6 / MASTER_SPEC §9 is TRUE only at flat FERA price — it should be
restated with the price assumption or hardened with a rebate cap.**

**PT-8/PT-9/PT-10:** freeze TWAP window+cap, define quality score over organic volume, publish
the staking-vs-LP yield target. All PARAMS.md items.

## 5. Cheapest attack + real data needed
- **Cheapest attack:** 2x-self-boosted minority self-dealer. cost/profit ≈ **0.5x**. **FAIL.**
- **Data needed:** real epoch fees-paid/earned per account, `AnchorStaking` boost distribution,
  FERA/USD price history for realized `g`, and the funding-graph clustering (memo 02) to detect
  self-dealing. Re-run `wash_bot.py` with measured β and the adopted PT-2 fix; target every cell
  cost/profit ≥ 10x (net-negative independent of FERA price).
