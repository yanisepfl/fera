# Emissions & tokenomics — where FERA comes from, and why it can't out-print revenue

FERA the token has a **fixed supply of 1,000,000,000 (1 billion), forever.** There is no inflation
knob. The supply breaks down as:

- **10% at genesis** — team, liquidity, and a treasury war-chest, all vested and timelocked.
- **90% emitted through usage only** — earned by the people who actually use the protocol, over
  roughly a four-year horizon.

This page explains how that 90% is emitted, who gets it, and the one rule that makes FERA's
tokenomics different from most: **emissions can never exceed the revenue the protocol earned.**

## The 85 / 5 / 10 emission split

Every weekly epoch, the emitted esFERA is split:

| Slice | Who | Why |
|-------|-----|-----|
| **85%** | **Liquidity providers** | Pro-rata to the fees your vault shares earned. Liquidity is FERA's one bottleneck, so the split is deliberately liquidity-maximal. |
| **5%** | **Traders** | Pro-rata to the fees they paid — a small rebate. Kept small on purpose: it's the safest slice (it roughly doubles the margin that makes wash-farming unprofitable) at no cost to routing, since routers choose pools by depth, not by rebate. |
| **10%** | **Treasury** | A protocol-owned war-chest that compounds into protocol-owned liquidity — the lever that helps seed liquidity when the token is young. |

A few honest details:

- **Only vault depositors earn the LP slice.** Providing liquidity directly (outside the vault)
  earns you swap fees but **zero emissions**. Emissions are the vault's exclusive draw.
- **Staking can boost your LP slice** up to ~2×, but that's a re-weighting of the fixed pool, not new
  tokens (see [Rewards & vesting](rewards-and-vesting.md)).
- Emissions arrive as **esFERA** and vest over ~6 months. Don't confuse this **85/5/10 emission
  split** with the **50/25/25 revenue split** — one is the token being emitted, the other is real
  fee revenue being distributed. They're different flows and FERA keeps them separate everywhere.

## The rule that matters: emissions ≤ revenue

Each epoch, the amount emitted is:

```
emitted = min( cap(t) , β × revenue )
```

- **`cap(t)`** is a fixed supply schedule — a logistic (S-curve) over the 900M usage bucket, spread
  across ~4 years (peaking around 9.73M FERA per week at the top of the curve). This is the ceiling
  from the *supply* side.
- **`β × revenue`** is the *revenue* bound. `β` is 0.8, and `revenue` is the protocol's actual fee
  revenue that epoch, valued in FERA at a manipulation-resistant 7-day time-weighted price. This is
  the ceiling from the *earnings* side.

Emissions are the **lower of the two.** When the revenue bound sits below the supply cap — which is
the case in the early life of the protocol — **issuance is gated by revenue.** FERA literally cannot
emit more value than it earned. In other words the token is **an earned claim on real activity, not a
subsidy** — not a promise printed against the future.

The [Transparency](transparency.md) page draws all three lines — the supply cap, the revenue bound,
and what actually got emitted (which can only ever touch the *lower* of the two). You can watch the
gate work, epoch by epoch.

## The honest asterisk: early emissions are small

This is the most important thing to understand, and the easiest to get wrong:

> **Because emissions are gated by revenue, and a young protocol earns little revenue, early
> emissions are small.** In the base case, only about **11%** of the 900M usage bucket emits over the
> first four years. The token can be worth very little at the start.

We say this plainly because the alternative — advertising a big early "emissions APR" to attract
deposits — would be both dishonest and self-defeating (an emission APR that depends on the token
price is reflexive and collapses on itself). **Do not deposit into FERA because of an emissions
number.** Deposit because the fee mechanism fits the flow in that pool. Emissions are a steady-state
claim on real activity that grows as usage grows — not a launch subsidy and not the reason to show
up.

The early liquidity that the protocol needs is seeded from the **treasury war-chest**, not from usage
emissions. That's the only design consistent with the "emissions ≤ revenue" rule.

## Why this design

Most token emissions are a subsidy: the protocol prints tokens to rent liquidity, the tokens inflate
faster than revenue, and the price bleeds. FERA inverts that: **the token can never inflate faster
than the protocol earns.** It's less exciting on day one — and far more honest about what the token
actually is.

---

Next: [Transparency →](transparency.md) · [Risks →](risks.md)
