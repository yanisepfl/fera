# Rewards & vesting: esFERA, staking, and the revenue share

FERA has one token, **FERA** (fixed supply, 1 billion, forever). You earn it through *usage*, but you
don't receive it as liquid FERA right away. You receive **esFERA**, which vests. This page explains
esFERA, the instant-exit haircut, staking, and the revenue share, and it is careful about language
because the words here matter legally.

## esFERA: escrowed FERA

When you earn emissions (by providing liquidity in a vault, or as a trader rebate), they arrive as
**esFERA**: non-transferable, escrowed FERA.

- **It vests linearly to FERA 1:1 over ~6 months** (182 days). As it vests, you can claim the vested
  portion as liquid FERA, no penalty.
- **Or you can exit instantly, at a 50% haircut.** If you don't want to wait, you can convert esFERA
  to FERA immediately, but you receive only **half**. The other half is forfeited.
- **Withdrawing your liquidity does not touch your esFERA.** Your grants keep vesting on their own
  schedule regardless of what you do with your LP position.

### The instant-exit haircut, in numbers

Instant exit takes a flat **50%** haircut. The forfeited half is split three ways, exactly:

- **1/3 is burned** (removed from supply forever),
- **1/3 goes to people who are still vesting** (patience is rewarded), and
- **1/3 goes to the revenue distributor** (which pays stakers, treasury, and ops).

So if you instant-exit **1,000 esFERA**:

| | Amount |
|---|--------|
| FERA you receive now | **500** |
| Forfeited | 500 |
| → burned | ~166.67 |
| → to vesting stakers | ~166.67 |
| → to revenue | ~166.67 |
| What you'd have gotten by waiting the full vest | **1,000** |

The Rewards page has a live **instant-exit calculator**: type any amount (or drag the slider) and it
shows exactly what you'd receive, what you'd forfeit, and where the forfeited part goes, *before*
you ever confirm. The point is that you can never take the haircut by accident. Waiting is almost
always the better deal unless you specifically need liquidity now.

## Staking (sFERA)

You can stake FERA to receive **sFERA**. Staking has **no voting, no gauges, and no bribes.**
Emissions in FERA follow *measured* fees, not votes, so there's nothing to lobby for. Staking gives
you three things:

1. **A boost on your own LP emissions, up to ~2×.** Staking increases *your* share of the
   liquidity-provider emission bucket. Two honest details: the boost applies **only to your LP
   emissions** (not to the trader rebate), and it is a *re-weighting of a fixed pool*. It changes
   your slice, it never mints new tokens. If everyone staked and boosted equally, the boosts would
   cancel out.
2. **A share of protocol revenue.** Half of FERA's real fee revenue (the 10% performance fee) flows
   to stakers. This is a **revenue share.** It is **variable and tied to protocol activity**, not a
   fixed or promised payout. When the protocol earns more, stakers receive more; when it earns less,
   they receive less. (See the language note below.)
3. **An optional time-lock** with linearly decaying multiplier points, if you want to commit longer
   for more weight.

## The revenue share, and a note on language

We are deliberate about how we describe staking rewards, and you should be too when you talk about
FERA:

- We say **"revenue share":** variable, activity-linked, paid out of fees the protocol actually
  earned.
- We do **not** say "dividend," "passive income," "yield on your stake," "guaranteed," or "fixed."
  Those words carry a specific legal meaning FERA does not intend and cannot back. The revenue share
  is not a promise of return; it's a share of whatever revenue happens.

This isn't marketing caution for its own sake. It's the same discipline that runs through the whole
protocol: **if we can't point to the on-chain transaction, we don't claim it.** See
[Transparency](transparency.md).

## Where emissions come from

Emissions are capped by revenue and split **85% to liquidity providers / 5% to traders / 10% to
treasury**. Crucially, **emissions can never exceed what the protocol actually earned** (bounded by
`β × revenue`, with β = 0.8). Early emissions are therefore *small* by design. The full mechanism
(and why you should not treat emissions as the reason to deposit) is in
[Emissions & tokenomics](emissions-and-tokenomics.md).

---

Next: [Emissions & tokenomics →](emissions-and-tokenomics.md) · [Transparency →](transparency.md)
