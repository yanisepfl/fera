# Memo 02 — M2 Flow Census: Bot vs Organic (Gates V3, fee calibration)

**Verdict: CONDITIONAL / informational.** Per MASTER_SPEC §11 and SHARED_CONTEXT V3, this is
a **calibration input, not a viability veto** — FERA monetizes bot, arb, wash, and organic
flow alike (that is the thesis). The purpose is to (a) classify the volume so Mechanism (1)
calibrates the MEME EWMA fee curve correctly, and (b) **quantify the post-gas-holiday volume
cliff**, which is the one genuine revenue risk hiding in the flow mix.

> Data note: no RH-Chain archive access this session. This memo delivers the **method**
> (runnable against a `Swap`-event export the moment Backend (4) indexes mainnet) and a
> **synthetic quantification** of the cliff. Numbers are illustrative until real data lands.

## 1. The classification problem

We want, per pool per epoch, a decomposition of volume into:
`organic` | `arb` (incl. RWA weekend-drift arb) | `mechanical/MM bot` | `wash/farm`.
For fee calibration we mainly need **organic vs mechanical**, and the **fee-elasticity** of
each class (does it leave when fees rise?). For the cliff we need the **gas-subsidy-dependent**
share.

## 2. Signals & method (five independent classifiers, then ensemble)

Each signal is computable from indexed `Swap` events (MASTER_SPEC §6) plus wallet funding
history from the RH-Chain archive. Use them as weak classifiers and combine (majority /
logistic ensemble) — no single signal is decisive.

1. **Wallet age / funding depth.** First-seen block of the swapping EOA (or of the router's
   ultimate signer via calldata/`tx.origin`). Freshly-funded wallets that trade once and go
   quiet, or wallets funded from a common source in a burst, skew bot/farm. Metric:
   distribution of `(first_tx_block → first_swap_block)` and funder in-degree.
2. **Inter-arrival timing entropy.** For each wallet, the entropy of inter-swap intervals.
   Humans are bursty-irregular (high entropy); naive bots are periodic (low entropy) or
   fixed-cadence (spikes at round intervals / every-N-blocks). Under ~100ms blocks, sub-second
   regularity is a strong bot tell. Metric: Shannon entropy of Δt histogram + autocorrelation
   at fixed lags.
3. **Round-trip / self-cross detection (wash tell).** Buy-then-sell of the same token by the
   same wallet (or a cluster) within a short window, net position ≈ 0, repeated. Metric:
   per-wallet net-inventory drift ≈ 0 while gross volume ≫ 0; A↔B↔A cycles in the transfer
   graph. This is the highest-value signal for wash/farm.
4. **Gas-holiday farming pattern.** Volume that is only rational because gas ≈ 0: tiny-notional
   high-frequency round-trips, dust swaps, sandwichable regularity, sequences whose expected
   PnL net of *normal* gas would be negative. Metric: per-swap `notional × implied_gas_cost@post_holiday`
   vs realized edge; flag flows that flip negative once gas returns.
5. **Cluster/funding-graph analysis.** Group wallets by common funder, identical gas settings,
   shared nonce cadence, or coordinated timing. A cluster acting as one agent is treated as one
   agent for both classification and (critically) boost/quality-score anti-gaming (memo 04).
   Metric: connected components in the funding+timing graph; Louvain/greedy modularity.

**RWA-specific:** weekend-drift arb is *expected, structural* flow (SHARED_CONTEXT §RWA). Tag it
separately by correlating swap direction/size with `|pool_price − Chainlink_feed|` and market-
hours state; it is not "toxic to remove," it is the LP income the RWA regime is designed to
harvest — but it is **fee-inelastic** (arb trades because mispricing > fee), which is exactly
why the RWA overlay fee can be aggressive.

## 3. Fee-calibration output (what Mechanism (1) needs)
- **Per-class fee elasticity.** Estimate how each class's volume responds to fee (from natural
  fee variation across existing pools/tiers). Organic retail is fee-elastic (leaves); arb and
  liquidation flow is fee-inelastic (stays). This is the single most important input: it tells
  Mechanism how high the MEME ceiling and RWA overlay can go before *elastic* volume leaves,
  while *inelastic* toxic volume keeps paying. Set the fee curve to price the inelastic classes.
- **EWMA window sizing.** The timing/entropy analysis gives the timescale of mechanical flow
  bursts → informs `MEME_EWMA_LAMBDA` / window so the fee reacts fast enough to a wash burst to
  actually capture it, without over-reacting to organic noise (PARAMS.md dependency PT-1).

## 4. Post-gas-holiday volume risk (the real finding)

RH-Chain's **90-day gas-fee holiday** started 2026-07-01 → ends **~2026-09-29**. Today is
2026-07-10: the holiday is **active**, so *all current volume is gas-subsidized*. A material
share of memecoin volume is plausibly gas-holiday-dependent bot/farm flow that has **no
economic purpose once gas returns** — high-frequency dust round-trips, farm churn, marginal
arb. When gas returns, that flow evaporates, and so do the fees FERA would earn on it.

**Why FERA cares even though "we monetize both":** we monetize bot flow *while it exists*. If
40% of memecoin volume is gas-holiday-only, then ~40% of MEME fee revenue is a **cliff at
day 90**, which cascades into the emission bound (`emitted ≤ β × revenue`) — emissions shrink
with revenue, which is *correct* (a dividend of activity, not a subsidy) but means **TVL rented
with emissions can leave right when the volume that justified it disappears**. This is a
liquidity-flight risk timed to a known date.

**Synthetic quantification (method, replace with real classification):**

| Assumed gas-holiday-dependent share of MEME volume | Post-holiday MEME fee revenue | Emission bound impact (β·rev) | Implied TVL that turns unprofitable* |
|---|---|---|---|
| 20% | −20% | −20% | modest |
| 40% (central bad case) | −40% | −40% | material — plan for it |
| 60% | −60% | −60% | severe — MEME-heavy TVL flight |

\*emissions fall with revenue, so emission-rented LPs' yield drops proportionally; the ones that
were there only for the emission APR rationally exit near day 90.

**Mitigations to hand GTM (7) / Mechanism (1):**
1. Don't over-seed emissions to MEME pools whose volume is gas-holiday-inflated; weight toward
   pairs with fee-inelastic (arb/organic) flow (RWA stock tokens, WETH majors).
2. Pre-announce the day-90 emission step-down so it is priced in, not a shock.
3. Use the census to publish an "organic-adjusted volume" metric so the market can't be fooled
   (and neither can our own quality score — memo 04 PT-9).

## 5. Deliverable status & data needed next
- **Method:** ready to run against a `Swap`-event + funding-graph export (Backend 4). I did not
  build a separate census script — it needs real event data to be anything but a mock; the five
  classifiers above are the spec for it, and the cluster/round-trip logic is reused by
  `wash_bot.py`'s attacker model.
- **Real data needed:** (1) RH-Chain `Swap` event history per memecoin pool; (2) wallet funding
  graph (first-fund tx + funder) from the archive; (3) gas-price schedule / holiday end
  confirmation; (4) a labeled seed set (a few known bots/farms) to fit the ensemble threshold.
- **Verdict:** CONDITIONAL — method sound; **the day-90 gas-holiday cliff is the item to size
  with real data before Mechanism freezes the emission schedule.**
