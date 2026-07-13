# FERA

**The liquidity layer that prices what others bleed.**

FERA is a Uniswap v4 liquidity layer on Robinhood Chain. It charges volatile, mechanical, and
weekend-arbitrage trading flow the fee it is actually worth. So the volatility that drains ordinary
liquidity providers pays FERA's providers instead. It also ships a managed vault, so you can provide
liquidity to a memecoin pool or a tokenized-stock pool without running a keeper.

This is the official documentation. It is written to be **checked, not trusted**: every number FERA
shows you is reproducible from public on-chain data. Where a claim is conditional, we say so. Where
a figure is a backtest rather than a live result, we label it. See
[Transparency](transparency.md) for how to verify us.

## What FERA is, in one breath

A Uniswap v4 **hook** sets the swap fee *per trade, based on live market conditions*. It runs high
when flow is toxic (violent memecoin moves, bots, weekend stock-token drift), and near-zero when
flow is benign. Traders always get to swap; they just pay what the moment is worth, and that fee
goes to liquidity providers. A managed **vault** runs a transparent, rule-based strategy on top, so
you can be a liquidity provider with one deposit.

## The three things worth knowing up front

1. **Fees, not promises.** FERA's fee changes with market conditions. It does **not** promise a
   yield. What you earn depends on the volume and volatility your pool actually sees.
2. **You only pay when you earn.** There is a **10% performance fee** on the swap fees your
   liquidity collects, and nothing else. No fee on your deposit, your withdrawal, your principal,
   or on any swap. If your position collects no fees, FERA takes nothing.
3. **Withdrawing is never blocked, but timing matters.** Your principal is always returnable (a hard
   on-chain rule). But if you withdraw within a short window of depositing (**30 minutes** for
   memecoin pools, **10 minutes** for stock-token pools), you forfeit the *fees* that position
   accrued in that window. This is an anti-sniping guard; it never touches principal.

## Who it's for

- **If you LP memecoins or chase emissions.** FERA gives you higher fee capture on violent pairs
  (the fee scales up exactly when the action is craziest) and an emissions-eligible, one-click way
  to hold the position. Read [What is FERA?](what-is-fera.md#for-a-degen) and be honest with
  yourself about the risk in the **Active** profile.
- **If you own tokenized stocks (NVDA, AAPL, GOOG…).** FERA turns the weekend drift that normally
  *costs* an LP into *income*, and offers a calm **Steady** risk profile built for exposure rather
  than a trading desk. Read [What is FERA?](what-is-fera.md#for-someone-lping-nvda).

## Start here

| Doc | Read it if you want to know… |
|-----|------------------------------|
| [What is FERA?](what-is-fera.md) | The whole idea in plain language. |
| [LP guide](lp-guide.md) | How to deposit, Steady vs Active, fees vs impermanent loss, the 10% fee, and withdrawing. |
| [How the dynamic fee works](how-fees-work.md) | The mechanism: the MEME volatility fee and the RWA weekend-drift fee, with the actual numbers. |
| [Rewards & vesting](rewards-and-vesting.md) | esFERA, the 6-month vest, the instant-exit haircut, staking, and the revenue share. |
| [Emissions & tokenomics](emissions-and-tokenomics.md) | Where FERA the token comes from, the 85/5/10 split, and why emissions can't exceed revenue. |
| [Transparency](transparency.md) | How every number on the site is reproducible on-chain. |
| [Security](security.md) | What the security review found and fixed. |
| [Risks](risks.md) | The honest list of what can go wrong. Read this before you deposit. |
| [Developers](developers.md) | Architecture, contracts, and how to build/deploy. |
| [FAQ](faq.md) | Quick answers to common questions. |

## A note on honesty

FERA is infrastructure, not a wealth machine. We never say "guaranteed," "risk-free," or "dividend."
A managed vault is the *simple, one-click, emissions-eligible* way to provide liquidity. We do
**not** claim it out-earns a skilled person managing their own position by hand. If any page here
reads like hype, treat that as a bug and check it against [Transparency](transparency.md).
