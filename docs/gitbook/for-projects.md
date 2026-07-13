# For projects: bootstrapping your token's liquidity on FERA

Most of this documentation is written for a liquidity provider. This page is written for a
different reader: a project team that has its own token and needs a liquid pool for it. It
describes a model, not a specific offer, a partnership, or a guarantee. Read the
[status note](#status-a-model-were-building-toward-not-a-live-offer) at the end before you plan
anything around it.

## The usual pattern

Most new tokens bootstrap liquidity the same way. The project sets aside a chunk of its own
supply and streams it to anyone who deposits into a pool for that token. It works, for a while,
because the incentive is real money to whoever farms it. But the project is paying for depth in
the one asset it can least afford to spend: its own token. When the incentive tapers off, or the
token price comes under the sell pressure that constant emission tends to create, the liquidity
that was only ever there for the incentive tends to leave with it. The project ends up having
rented its own liquidity, paid for in dilution.

FERA's pools are built around a different idea: **the fee mechanism does the bootstrapping
instead of the token.**

## What a project's own pool can earn

If your project runs a pool for its token on FERA, three separate things can happen for you, and
they stack.

### 1. Real trading-fee yield, and not only in your own token

FERA pools are paired against a liquid quote asset (something like WETH or USDG), the same way
every pool on the chain is quoted. That pairing matters more than it sounds like it should:
because the pool's trading fees are collected across both sides of the pair, a real share of what
the pool earns settles in that liquid quote asset, automatically, as part of how FERA's fee
mechanism works, not as something your team has to build, run, or manage. You are not left
holding a pile of your own token and calling it yield. Some of what the pool earns is a blue-chip
asset from day one.

This is the core difference from paying incentives out of your own supply: instead of the
project subsidizing depth with dilution, the pool's own trading activity, priced by FERA's
dynamic fee (see [How the dynamic fee works](how-fees-work.md)), is what pays for it, in an asset
that isn't your token.

### 2. esFERA emissions, if the FERA team flags the pool eligible

Separately from fee yield, a pool can also be flagged **emissions-eligible**, meaning its
depositors earn esFERA on top of fee yield, the same emissions any FERA vault depositor earns
(see [Rewards & vesting](rewards-and-vesting.md)).

Be clear-eyed about the word "if." Emissions eligibility is **not automatic and not guaranteed**.
It's a decision the FERA team makes per pool, the same way not every pool qualifies for the MEME
fee regime in the first place (a pool with no real volatility doesn't clear the bar either). The
reason isn't arbitrary: emissions are a shared, revenue-capped resource (see
[Emissions & tokenomics](emissions-and-tokenomics.md)), and flagging every newly created pool
eligible by default would invite exactly the kind of wash-volume, self-dealing farming that the
emissions design is built to exclude. So: your project's pool earning fee yield does not, by
itself, mean it earns emissions. Ask, don't assume.

### 3. A revenue share and an emissions boost, if you stake your FERA

This one isn't specific to running a pool, it's what staking already does for any FERA holder
(see [Rewards & vesting](rewards-and-vesting.md#staking-sfera)), but it stacks on top of the
above if your project happens to hold FERA. Staking FERA gets you:

- **A share of protocol revenue.** Half of FERA's real fee revenue (the 10% performance fee) flows
  to stakers. It's a variable revenue share tied to actual protocol activity, not a fixed payout,
  not a dividend, and not a promise.
- **A boost of up to ~2x on your own LP emissions**, if your pool is emissions-eligible in the
  first place. The boost re-weights your slice of a fixed emissions pool; it doesn't mint anything
  new.

So a project that (a) runs a pool for its token, (b) gets that pool flagged emissions-eligible,
and (c) stakes whatever FERA it holds, is stacking three independent revenue sources, fee yield,
emissions, and a revenue share plus boost, on top of one deposit. Each layer is optional and each
is real only to the extent the pool actually sees volume and the team actually flags it. None of
it is printed out of your own token.

## What this is not

- **Not a guarantee that any specific pool gets flagged emissions-eligible.** That's a team
  decision, made pool by pool, and it can say no.
- **Not a claim that a FERA vault out-earns a project (or anyone) hand-managing their own
  liquidity position.** It doesn't, and we don't market it that way. See
  [LP directly vs the vault](lp-guide.md#7-lp-directly-vs-the-vault-open-liquidity). A project is
  free to LP its own pool directly, with full manual control, and just not receive emissions,
  the same trade-off any liquidity provider makes.
- **Not a yield number.** Nothing here is a percentage, a projection, or a promise. What a pool
  earns depends on the volume and volatility it actually sees, which varies and can be low. See
  [Risks](risks.md).
- **Not investment advice, and not a securities offering.** This page describes a liquidity
  mechanism available to any project's own token pool, not an investment product FERA is selling.

## Status: a model we're building toward, not a live offer

Today, creating a new pool on FERA is a keeper-controlled action, not something a project can do
itself. **Permissionless pool creation for project tokens is being built**, as a separate,
parallel piece of work, so that a project can bring its own token's pool into existence without
needing FERA to do it for them. This page describes the model that creation flow is being built
toward: a project-created pool behaves like any other MEME pool on FERA, subject to the same fee
mechanism, the same emissions rules, and the same eligibility decisions described above.

Until that ships, everything above is a description of how the mechanism is designed to work, not
a live feature you can go use today, and not a commitment to a ship date. If your project wants to
talk to FERA about a pool for your token in the meantime, that's a conversation to have directly,
not something this page can promise on the protocol's behalf.

## Where to go next

- [What is FERA?](what-is-fera.md) for the whole idea in plain language.
- [How the dynamic fee works](how-fees-work.md) for the mechanism that turns trading flow into
  fee yield.
- [Emissions & tokenomics](emissions-and-tokenomics.md) for how esFERA is earned, capped, and
  split, and why it can't exceed protocol revenue.
- [Rewards & vesting](rewards-and-vesting.md) for staking, the revenue share, and the emissions
  boost.
- [LP guide](lp-guide.md) for how deposits, risk profiles, and the 10% performance fee actually
  work, the same mechanics apply whether the depositor is an individual or a project treasury.
- [Developers](developers.md) if your team wants to look at the contracts directly.

---

Next: [What is FERA? →](what-is-fera.md) · [LP guide →](lp-guide.md)
