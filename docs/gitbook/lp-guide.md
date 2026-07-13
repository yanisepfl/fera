# LP guide — providing liquidity on FERA

This is the practical guide: how to deposit, how to choose a risk profile, what you earn, what you
can lose, and how to withdraw. Read [Risks](risks.md) alongside it.

## 1. Deposit

1. **Pick a pool.** The Earn page lists every pool with its live fee, its fee-yield APR and emissions
   APR shown *separately* (never blended into one hype number), its TVL, and how its depth compares
   to competing pools.
2. **Choose your risk profile** (see below). Memecoin pools offer **Active** only; stock-token (RWA)
   pools offer both **Steady** and **Active**.
3. **Deposit one or both assets.** You can deposit a single asset; the vault swap-assists to the
   right ratio for the profile you chose. You receive a normal **ERC-20 share token** for that pool
   and profile.
4. **That's it.** The vault runs the strategy. Your fees auto-compound into your share value; any
   FERA emissions accrue separately as esFERA (see [Rewards & vesting](rewards-and-vesting.md)).

There's a short deposit cooldown and a price-sanity check on the way in (this protects existing
depositors from a class of manipulation — it's a guard, not a lock-up).

## 2. Steady vs Active — choosing a risk profile

Every FERA vault shapes your liquidity into **bands** — ranges of price where your money sits and
earns fees. The risk profile decides *which* bands your money is in. The trade-off is always the
same: **the more concentrated near the current price, the more fees you capture and the more
impermanent loss you take.**

| | **Active** | **Steady** |
|---|-----------|-----------|
| Where your money sits | Concentrated near the current price (core + mid bands) | Wide / tail bands, always-in-range |
| Fee capture | Higher — it sits where most volume trades | Lower — a thinner slice of the fees |
| Impermanent loss | Higher — a big price move hits it harder | Lower — the wide range keeps you in-range through swings |
| Built for | Yield-seeking capital comfortable with volatility | Conservative capital — e.g. someone LPing a stock token who wants exposure, not a trading desk |
| Available on | Memecoin **and** stock-token pools | Stock-token (RWA) pools only |

Each profile is its own managed share class with its own value, its own fees, and its own share
symbol (`fACT-…` for Active, `fSTD-…` for Steady). You can hold both. You pick one per deposit.

> **Why memecoin pools don't offer Steady.** A wide, steady range on a memecoin is barely different
> from not providing liquidity at all — you'd sit mostly out-of-range and earn almost nothing. The
> Steady profile ships where it actually fits: the stock-token pools, for the person who wants calm
> exposure to NVDA or AAPL.

## 3. What you earn

Two separate streams, always shown separately:

- **Fee yield.** Your share of the swap fees the pool collects, net of the 10% performance fee
  (below). This is real, on-chain revenue. It varies with volume and volatility.
- **Emissions.** FERA tokens (delivered as esFERA), earned *only* by vault depositors. See
  [Emissions](emissions-and-tokenomics.md) — and note that early emissions are deliberately small
  because they are capped by protocol revenue.

## 4. Fees vs impermanent loss — the honest version

**Impermanent loss (IL) is not a FERA thing — it's a liquidity-provider thing.** Any time the two
assets in a pool change price relative to each other, an automated-market-maker position ends up
worth less than if you'd just held the two tokens. That's IL. FERA does **not** remove it. Over the
same price path, your IL in a FERA pool is the same as in a vanilla pool.

What FERA changes is the **other** side of the ledger: **fee capture**. FERA's regime fee collects
more on the flow that would otherwise bleed you. The bet is that on volatile and weekend-drift flow,
the extra fees more than offset the IL — but this is a bet that depends on your pool seeing real
volume, not a guarantee.

- On **memecoin** pools, IL is *priced, not fought*: the volatility fee rises as the price moves
  violently, so IL is compensated by fee income rather than chased with constant repositioning. Your
  principal isn't churned (see below).
- On **stock-token** pools, the tight Steady/Active bands are oracle-anchored and the strategy
  widens or partially withdraws off-hours to reduce the Monday-gap hit — it reduces IL exposure, it
  does not eliminate it.

There is no market condition where FERA promises you come out ahead. A quiet pool with no volume
earns you little, and a sharp adverse move still costs you IL. See
[Risks](risks.md#impermanent-loss).

### How the memecoin strategy actually handles your principal

FERA does **not** say "we never rebalance," and it does not churn your principal either. The honest
version:

- Your principal is placed once as a **shaped ladder** of bands — concentrated near price for fee
  capture, with a full-range tail for crash coverage (weights roughly 30% core / 40% mid / 30%
  tail). **No strategy action ever closes or swaps a principal band**, so your principal never
  realizes impermanent loss from the strategy itself.
- What *does* move is **fee income**: collected fees are dripped daily into fresh bands at the
  current price, so the shape follows the market using income only.
- In a fast, sustained trend the drip can lag. So the strategy *may* recenter principal — but only
  when **every** on-chain condition holds: at-spot depth has stayed degraded for **≥24 hours**, it's
  been **≥7 days** since the last recenter, and the pool's time-weighted price is within a **±5%**
  sanity band (with slippage caps and randomized timing). If those conditions aren't met, the
  contract reverts the attempt. A keeper can trigger it; it can never override the rules.

Every drip, consolidation, and recenter is an on-chain action with a justification you can inspect
in the pool's strategy log.

## 5. The 10% performance fee — only when you earn

FERA makes money **one way**: a **10% performance fee on the swap fees your liquidity collects.**
This is immutable (it can never be changed) and it is the *only* fee FERA charges you.

- **0% on swaps.** No protocol fee is ever taken from a trade, and no trade is ever blocked. The
  whole dynamic fee is the liquidity providers'.
- **0% on principal.** Deposits, withdrawals, rebalances, compounds, off-hours widens — none touch
  your principal.
- **10% of collected fees, and nothing when there are none.** When the vault collects fees, exactly
  10% is skimmed. If your position collects no fees, FERA takes nothing. Every APR shown on the site
  is already net of this fee.

> **The honest caveat.** Because the 10% skim raises your break-even, a FERA pool has to charge a bit
> more than a vanilla pool to beat it — above ~33.3 bps. That's exactly why the memecoin fee floor is
> set to **0.34%**: it clears the hurdle even at the floor. FERA also won't deploy the memecoin fee
> regime on pairs with no volatility, because a quiet pool wouldn't clear it.

Where does the 10% go? It's real revenue, split immutably **50% to stakers / 25% to treasury / 25%
to ops**. That's a different split from emissions — don't confuse the two. See
[Emissions](emissions-and-tokenomics.md) and [Rewards & vesting](rewards-and-vesting.md).

## 6. Withdraw

You can withdraw any time. **Withdrawals are never pausable and never blocked** — this is a hard
on-chain invariant. Your principal is returned in full. Any pending esFERA keeps vesting;
withdrawing your shares does not forfeit it.

### The early-exit window

There is one thing to know about *timing*. To stop bots from sniping the exact high-fee moments FERA
creates (adding liquidity right before a big fee and yanking it right after), there's a short
**fee-forfeiture window** after each deposit:

- **Memecoin pools: 30 minutes. Stock-token pools: 10 minutes.**
- If you withdraw *inside* the window, you forfeit the swap fees that position accrued during it. The
  penalty **decays linearly to zero** across the window — the longer you wait, the less is at risk,
  and it hits zero at the end.
- **It never touches your principal, and it never blocks the withdrawal.** You can always leave;
  you'd just leave some accrued fees behind.
- Forfeited fees are **donated to the liquidity providers still in range** — which means the
  flip-side is in your favour too: when *other* people bail early, their forfeited fees are paid to
  you while you stay put.

The Withdraw screen shows you, live, exactly how much you'd forfeit right now and counts down to when
the penalty hits zero — so you can never trip over it by accident. If you're past the window, it says
so and you keep 100% of your fees.

## 7. LP directly vs the vault (open liquidity)

Anyone can provide liquidity to a FERA pool **directly** — the hook is permissionless, you pick your
own range, you have full manual control, and you earn swap fees. What you *don't* get by LPing
directly is **FERA emissions** — those accrue only to vault share holders. The vault is the managed,
one-click, emissions-eligible door.

**Straight talk:** a skilled liquidity provider hand-managing a tight range can capture more fees per
dollar than the vault's ladder. We do **not** market the vault as higher-yield. It's the managed,
emissions-eligible, passive option — and the sophisticated providers who LP directly deepen the same
pool for everyone. Choose the vault for management and emissions; choose direct if you want to run
your own range and don't need the token.

---

Next: [How the dynamic fee works →](how-fees-work.md) · [Rewards & vesting →](rewards-and-vesting.md) · [Risks →](risks.md)
