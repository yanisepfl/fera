# Risks — read this before you deposit

Providing liquidity on FERA can lose you money. This page is the honest list of how. None of it is
hidden in fine print; it's here because you should decide with it in front of you.

## No guaranteed yield

FERA does not promise a return, and no one should tell you it does. What you earn depends on the
volume and volatility your pool actually sees — both of which vary and can be low. A quiet pool
earns little. There is **no** "guaranteed," "fixed," or "risk-free" yield anywhere in FERA, and any
source claiming otherwise is wrong.

## Impermanent loss

**Impermanent loss (IL) is inherent to providing liquidity, and FERA does not remove it.** When the
two assets in a pool move in price relative to each other, your position ends up worth less than if
you'd simply held the two tokens. Over the same price path, your IL in a FERA pool is the same as in
a vanilla pool.

FERA's bet is that its market-aware fee captures *more fees* on volatile and weekend-drift flow than
a vanilla pool would — enough, on the flow that matters, to more than offset IL. But that's a bet
that depends on real volume, **not a guarantee**. A sharp adverse move can still leave you worse off
than holding, especially in the **Active** profile, which concentrates near price and takes more IL.
The **Steady** profile takes less IL (and earns thinner fees) — but not zero. Understand IL before
you choose a profile. See the [LP guide](./lp-guide.md#4-fees-vs-impermanent-loss--the-honest-version).

## Smart-contract risk

FERA is smart-contract software. It has been audited (a Sherlock contest plus a boutique review),
money-path contracts are non-upgradeable, parameters are either immutable or behind a 48-hour
timelock, and there is a live bug bounty. **This reduces risk; it does not eliminate it.** Audited,
non-upgradeable protocols have still been exploited — Bunni, Gamma, and Cork all shipped and still
suffered losses. Treat any DeFi deposit as capital you can afford to lose, and don't deposit more
than you'd be comfortable losing to a bug.

## The vault does not beat a skilled self-managed position

If your goal is maximum fee capture per dollar and you have the skill and time, **hand-managing your
own tight range will typically out-earn the vault.** The vault is the *managed, one-click,
emissions-eligible* option with a risk-profile choice — not a way to beat a professional. We state
this because overselling it is the easiest mistake to make. [Details.](./lp-guide.md#7-lp-directly-vs-the-vault-open-liquidity)

## The early-exit fee-forfeiture window

If you withdraw within **30 minutes** (memecoin pools) or **10 minutes** (stock-token pools) of a
deposit, you forfeit the fees that position accrued in that window. It's an anti-sniping guard, it
**never touches your principal, and it never blocks your withdrawal** — but if you deposit and leave
quickly, you leave some fees behind. The penalty decays to zero over the window, and the Withdraw
screen shows you the exact amount live. [Details.](./lp-guide.md#the-early-exit-window)

## The instant-exit haircut on esFERA

Emissions arrive as **esFERA** and vest over ~6 months. If you exit early, you take a **50%
haircut** — you receive half, forfeit half. That's a real, chosen loss, and the Rewards page
calculator shows it exactly before you confirm. Waiting the vest costs you nothing; the haircut is
only for people who want liquidity now. [Details.](./rewards-and-vesting.md#the-instant-exit-haircut-in-numbers)

## RWA and geo-fencing

FERA's stock-token (RWA) pools provide **liquidity infrastructure for tokenized assets** — they are
**not** securities offerings, and using FERA is **not** "investing in NVDA" or "buying stocks."
Because of that, **deposits to stock-token pools are geo-fenced by jurisdiction** — some countries
are blocked from depositing based on configuration. (Swaps are never gated; only vault deposits are
geo-restricted.) The specific country list is set by legal review. If your jurisdiction is blocked
from depositing, that's why.

There is also a market-structure risk specific to these pools: tokenized stocks drift from the cash
price when the underlying market is closed and reconcile at the next open. FERA's strategy widens
fees and partially withdraws off-hours to reduce the hit, but **a large Monday gap can still cost
your position** — it's mitigated, not eliminated.

## Oracle and market-condition risk

Stock-token pools depend on Chainlink price feeds. FERA's fee logic is built to fail *static* (hold
position) rather than fail open if a feed is stale, and swaps never revert on an oracle problem. But
oracle risk is real, and extreme or unusual market conditions can produce outcomes the strategy's
guardrails bound but don't prevent.

## Token risk

FERA has a fixed 1B supply and emissions can never exceed revenue — but the token can still be worth
very little, especially early (this is expected: early emissions are small by design). Do not deposit
because of an emissions number. [Emissions.](./emissions.md#the-honest-asterisk-early-emissions-are-small)

---

If any FERA doc or screen reads like it's promising something this page contradicts, believe this
page and check it on the [Transparency](./transparency.md) page. Back to the [index](./README.md).
