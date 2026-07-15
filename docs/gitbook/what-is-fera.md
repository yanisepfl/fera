# What is FERA?

FERA is a way to **provide liquidity** (to be the counterparty that traders swap against) on
Robinhood Chain, and get paid better for it than a plain liquidity pool would.

It has two parts:

1. **A smart fee (the hook).** FERA runs on a Uniswap v4 "hook", a small piece of code that sets
   the swap fee *per trade, based on live market conditions*. When flow is dangerous to liquidity
   providers (violent memecoin moves, bots, weekend stock-token drift), the fee goes up. When flow
   is benign, the fee goes down. Traders always get to swap; they just pay what the moment is worth.
2. **A managed vault.** You deposit into a vault, receive a normal ERC-20 share token, and the vault
   runs a transparent, rule-based strategy for you. No keeper to run, no ranges to rebalance by
   hand. You can withdraw whenever you want.

## The core idea

Ordinary liquidity providers lose money to two things: **volatile flow** (bots and sharp price
moves pick them off) and **structural arbitrage** (tokenized stocks drift from their real price over
the weekend, and someone arbitrages that gap at the liquidity provider's expense).

FERA's bet is simple: **that flow isn't the enemy. It's underpriced.** Instead of trying to block
bots or fight arbitrageurs, FERA charges them a fee that matches how toxic their flow is, and that
fee goes to you, the liquidity provider.

- **Memecoin pools:** the fee rises with realized volatility, from a floor of **0.34%** up to **3%**
  (and a hard cap of 5% on one-sided sell pressure). The more violent or mechanical the flow, the
  more you earn. Wash-trading and volume bots become a fee source by design.
- **Tokenized-stock pools (RWA):** the fee is near-zero (~2 bps) while the underlying market is
  open, and widens (30–100 bps) when it's closed, scaling with how far the on-chain price has
  drifted from the Chainlink oracle. The weekend arbitrageur pays you for the drift instead of
  taking it from you.

The exact formulas, with worked numbers, are in [How the dynamic fee works](how-fees-work.md).

FERA does **not** change your impermanent loss. Over the same price path, your IL is the same as it
would be in a vanilla pool. The entire difference FERA makes is **fee capture**: you collect more
of the fees on the flow that matters. (See [Risks](risks.md) for what impermanent loss is and why it
still applies.)

## For a degen

You already LP the hot WETH/memecoin pairs and chase emissions. FERA gives you:

- **Higher fee capture on violent pairs.** The fee scales up exactly when the action is craziest. A
  dump that would bleed a vanilla LP instead pays an elevated (asymmetric) fee.
- **A token to farm, honestly.** Depositing into the vault makes you eligible for FERA emissions
  (paid as esFERA). Directly LPing the same pool does *not* earn emissions. The vault is the only
  door to them. But read [Emissions](emissions-and-tokenomics.md) first: early emissions are
  **small** by design, because emissions are capped by real protocol revenue. We are not selling you
  a fat emission APR.
- **The "Active" risk profile.** On memecoin pools, a band near the price does the fee capture while
  a wide base holds your position through big moves, so the strategy earns from volatility instead of
  churning your principal to chase it. You still take impermanent loss when the price moves; that's
  the trade-off for the higher fee capture.

## For someone LPing NVDA

You own tokenized stocks (NVDA, AAPL, GOOG…) and now they trade on-chain 24/7. You want to earn on
the shares you already hold, without becoming a market maker. FERA gives you:

- **The weekend-drift story, in your favour.** Your stock tokens drift from the cash price over the
  weekend and snap back at Monday's open. In a normal pool, that reconciliation is a recurring
  *loss* to you: you're the one being arbitraged. FERA's RWA fee turns that same drift into
  recurring *income*: the arbitrageur pays a widened fee to close the gap.
- **The "Steady" risk profile.** Your liquidity sits in a wide range that stays in-range through
  crashes and rebounds, so less impermanent loss is realized. You earn a thinner but steadier slice
  of fees. It's built for exposure, not for running a trading desk.
- **One-click, single-asset deposit.** Deposit one side; the vault handles the rest.

A caution for this reader specifically: FERA provides **liquidity infrastructure**, not securities.
We don't help you "invest in NVDA" or "buy stocks." Deposits to stock-token pools are geo-fenced by
jurisdiction (swaps are never gated). See [Risks](risks.md#rwa-and-geo-fencing).

## What FERA is *not*

- **Not a yield product with a number on it.** There is no "X% APY." Your earnings depend on volume
  and volatility, both of which vary.
- **Not a way to beat a professional market maker.** A skilled person hand-managing a tight range
  will typically capture more fees per dollar than the vault. The vault sells *management,
  emissions-eligibility, simplicity, and a risk-profile choice*, not higher yield than a pro. We're
  explicit about this because it's the easiest thing to overstate.
- **Not an MEV solution (yet).** v1 *prices* toxic swap flow through fees. It does not auction the
  block or "capture the MEV." That's a v2 roadmap idea, not a v1 claim.
- **Not custodial of your principal.** Money-path contracts are non-upgradeable; the protocol cannot
  pause your withdrawals or touch your principal.

## Where FERA runs

Robinhood Chain is a permissionless Arbitrum Orbit L2 with ~100ms blocks, ETH for gas, and Chainlink
as the chain's oracle infrastructure. Uniswap (v2/v3/v4) is the chain's primary AMM, and ~95
Robinhood-issued stock tokens trade there 24/7 alongside memecoins. FERA deploys pools for pairs
that are *already trading*, so there's real flow to price from day one.

---

Next: [How to LP →](lp-guide.md)
