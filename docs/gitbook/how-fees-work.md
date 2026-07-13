# How the dynamic fee works

This page explains the mechanism behind FERA's fee, the part that makes it different from a plain
pool. It is the reader's version of the frozen mathematical spec
([`docs/mechanism/MECHANISM_SPEC.md`](../mechanism/MECHANISM_SPEC.md)), with the actual numbers but
without the on-chain bit-packing. Every value here is a fixed protocol constant.

The one rule that governs everything: **the fee is set per swap, and the swap never reverts because
of the fee.** The hook computes a fee, clamps it into a safe range, and returns it. It never blocks a
trade for a fee or oracle reason. It runs inside the ~40k gas budget of a Uniswap v4 hook.

There are two regimes: **MEME** (memecoin pools) and **RWA** (tokenized-stock pools).

## MEME: a fee that rises with volatility

The thesis: impermanent loss is driven by volatility, so instead of *fighting* volatility with
constant repositioning, FERA *charges* for it. The more violent the flow, the higher the fee, and
that fee compensates liquidity providers for the risk that same volatility creates.

**How it measures volatility.** On every swap, the hook reads the pool's price move (in "ticks," a
native Uniswap unit where one tick ≈ one basis point of return) and folds it into a fast, on-chain
estimate of realized volatility (an exponentially-weighted moving average). No oracle, no off-chain
input. The signal is already in the pool.

**How volatility becomes a fee.**

- **Floor: 0.34%.** In a quiet market the fee sits at the floor. (It's 0.34%, not 0.30%, on purpose:
  after the 10% performance fee, a FERA pool has to clear ~33.3 bps to beat a vanilla 30 bps pool,
  and 0.34% clears it even at the floor.)
- **It scales up with volatility, to a 3% ceiling.** As realized volatility rises, the fee rises
  linearly toward a 3.00% cap.
- **An extra charge on one-sided sell pressure, to a 5% hard max.** In a dump (sustained one-sided
  selling, the flow most toxic to liquidity providers) an asymmetric adder stacks on top, up to a
  hard maximum of **5.00%**. Buys in the same moment (dip-buying that heals the pool) are *not*
  surcharged, so arbitrage can repair the pool at the cheaper base fee. Asymmetry by design.

**Worked examples** (from the reference engine in
[`docs/mechanism/sims/`](../mechanism/sims/)):

| Scenario | Fee applied |
|----------|-------------|
| Quiet market | **0.34%** (floor) |
| Pump (buy or sell) | **~1.06%** |
| Dump, the buy (dip-arb) side | **~1.36%** |
| Dump, the sell side | **~3.07%** (base + sell-side adder) |

**Anti-manipulation: the ratchet.** The volatility estimate rises fast and falls slow. That closes
the obvious attack ("push volatility down cheaply, then dump at the low fee") because bleeding the
estimate back to the floor from a high level would take on the order of a hundred fee-paying swaps.
It also means the fee errs slightly high during a genuine cool-down, which is the correct direction
to err (it favours the liquidity provider). An attacker who oscillates the price to inflate the fee
just pays the inflated fee on their own swaps.

## RWA: a fee that prices weekend drift

Tokenized stocks trade on-chain 24/7, but the underlying equity market is closed nights and
weekends. So the token price drifts from the last cash price while the market is shut, and snaps back
at the next open. That reconciliation is a structural arbitrage, and in a vanilla pool the liquidity
provider is the one being arbitraged. FERA's RWA fee flips it into income.

**The market-hours schedule** is encoded on-chain (open 09:30 ET, close 16:00 ET, weekday bitmap,
DST offset, holidays). A keeper can flip only the bounded inputs (DST, holiday, early-close for the
current day). It cannot change trading hours.

**The fee** reads the Chainlink price feed and measures how far the on-chain pool price has drifted
from it:

- **Market open: ~2 bps base.** Near-zero while the equity market is live, to keep normal flow
  elastic.
- **Market closed: 30 bps base**, plus **+20 bps of fee for every 1% the pool has drifted from the
  oracle**, up to a **100 bps ceiling**. A typical 1–3% weekend gap therefore prices at roughly
  30–90 bps, enough to pay the liquidity provider while still leaving the arbitrageur a profit for
  closing the gap.

| Scenario | Fee |
|----------|-----|
| Open / quiet | **~3 bps** |
| Closed / 2% drift | **~70 bps** |
| Closed / 5%+ drift | **100 bps** (ceiling) |
| Oracle stale during market hours | **3.00% flat** (blind-pool guard, never reverts) |

**Off-hours staleness is expected, not a failure.** The equity feed only prints during market hours,
so its last print *is* the reference the weekend overlay charges against. Only *in-hours* staleness
beyond a heartbeat is treated as a real oracle failure. Even then the pool charges a high flat
fee (3%) rather than reverting a swap, so it can't be cheaply picked off while the feed is down.

**The only swap-blocking condition** the design permits (an extreme-deviation circuit that would
block *deviation-worsening* swaps when the pool is >10% from a healthy oracle) ships **disabled by
default**, pending further security modelling. v1 preserves the "never revert a swap" rule.

## What the fee does *not* do

- It does not remove impermanent loss. Over the same price path, your IL is identical to a vanilla
  pool. The fee changes what you *collect*, not what you *lose to price*. See
  [Risks](risks.md#impermanent-loss).
- It does not charge traders a protocol fee. The entire dynamic fee is the liquidity providers'; FERA
  takes only its 10% performance fee, and only from fees actually collected. See
  [the 10% performance fee](lp-guide.md#5-the-10-performance-fee-only-when-you-earn).
- It does not "capture MEV." v1 *prices* toxic swap flow; auctioning the block is a v2 idea, not a v1
  claim.

---

Next: [Rewards & vesting →](rewards-and-vesting.md) · [Emissions & tokenomics →](emissions-and-tokenomics.md)
