# FERA — User Documentation

Plain-language docs for people using FERA. No jargon you don't need, no promises we
can't keep. Every number FERA shows you is reproducible from on-chain data — see
[Transparency](./transparency.md) for how to check us.

> **What FERA is, in one line.** A Uniswap v4 liquidity layer on Robinhood Chain that
> charges volatile, mechanical, and weekend-arbitrage trading flow the fee it's actually
> worth — so the volatility that drains ordinary liquidity providers pays FERA's providers
> instead. Plus a managed vault, so you can provide liquidity to a memecoin or a tokenized
> stock pool without running a keeper.

## Start here

| Doc | Read it if you want to know… |
|-----|------------------------------|
| [What is FERA?](./what-is-fera.md) | The whole idea in plain language — for a degen and for someone LPing NVDA. |
| [LP guide](./lp-guide.md) | How to deposit, Steady vs Active, fees vs impermanent loss, the 10% fee, and withdrawing. |
| [Rewards & vesting](./rewards-and-vesting.md) | esFERA, the 6-month vest, the instant-exit haircut, staking, and the revenue share. |
| [Emissions](./emissions.md) | Where FERA the token comes from, the 85/5/10 split, and why emissions can't exceed revenue. |
| [Transparency](./transparency.md) | How every number on the site is reproducible on-chain. |
| [FAQ](./faq.md) | Quick answers to common questions. |
| [Risks](./risks.md) | The honest list of what can go wrong. Read this before you deposit. |

## The three things worth knowing up front

1. **Fees, not promises.** FERA's fee changes with market conditions (higher when flow is
   toxic or the market is closed, near-zero when flow is benign). It does **not** promise a
   yield. What you earn depends on the volume and volatility your pool actually sees.
2. **You only pay when you earn.** There is a **10% performance fee** on the swap fees your
   liquidity collects — and nothing else. No fee on your deposit, your withdrawal, your
   principal, or on any swap. If your position collects no fees, FERA takes nothing.
   ([Details](./lp-guide.md#5-the-10-performance-fee--only-when-you-earn).)
3. **Withdrawing is never blocked, but timing matters.** Your principal is always returnable
   (this is a hard on-chain rule). But if you withdraw within a short window of depositing
   (**30 minutes** for memecoin pools, **10 minutes** for stock-token pools), you forfeit the
   *fees* that position accrued in that window. This is an anti-sniping guard; it never touches
   principal. ([Details](./lp-guide.md#the-early-exit-window).)

## A note on honesty

FERA is infrastructure, not a wealth machine. Where a claim is conditional, we say so. Where a
number is a backtest rather than a live result, we label it. We never say "guaranteed,"
"risk-free," or "dividend." A managed vault is the *simple, one-click, emissions-eligible* way
to provide liquidity — we do **not** claim it out-earns a skilled person managing their own
position by hand. If any doc here reads like hype, treat that as a bug and check it against
[Transparency](./transparency.md).
