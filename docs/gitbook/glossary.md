# Glossary

Plain definitions for the terms you'll meet in these docs. Where a term has a fuller page, it links
to it.

- **Liquidity provider (LP).** The person whose tokens sit in a pool so traders have something to
  swap against. LPs earn the swap fees and carry the risk (see [impermanent loss](#impermanent-loss)).

- **Pool.** A pair of tokens (e.g. a memecoin and a liquid quote asset, or a tokenized stock and a
  quote asset) that people trade between. Each pool has its own fees and its own risk.

- **MEME pool.** A pool for a memecoin. Its fee rises with realized volatility. See
  [How the dynamic fee works](how-fees-work.md#meme-a-fee-that-rises-with-volatility).

- **RWA pool (tokenized-stock pool).** A pool for a tokenized real-world asset such as a stock. Its
  fee is near-zero while the underlying market is open and widens when it's closed. Deposits are
  geo-fenced; swaps are never gated. See [Risks](risks.md#rwa-and-geo-fencing).

- **The hook.** A small piece of on-chain code (a Uniswap v4 "hook") that sets the swap fee **per
  trade, based on live market conditions**. It never blocks a trade and never takes a protocol fee.
  See [What is FERA?](what-is-fera.md).

- **Dynamic fee.** The per-trade swap fee the hook computes: high when flow is toxic, near-zero when
  it's benign. It goes to LPs, not to FERA.

- **The vault.** The managed, one-click way to provide liquidity: you deposit, receive a share
  token, and the vault runs a rule-based strategy for you. It is **not** a way to out-earn a skilled
  self-managed position. See the [LP guide](lp-guide.md).

- **Share token.** A normal ERC-20 you receive when you deposit into a vault. It represents your
  slice of that pool-and-profile. Its value grows as fees accrue. `fACT-…` = Active, `fSTD-…` =
  Steady.

- **Steady / Active (risk profiles).** How your money is shaped in the pool. **Active** leans toward
  a near-price band for more fee capture and more impermanent loss. **Steady** sits in a wide range
  for less of both. Memecoin pools offer Active only; stock-token pools offer both. See the
  [LP guide](lp-guide.md#2-steady-vs-active-choosing-a-risk-profile).

- **Base / limit / idle.** The three parts of a vault position. The **base** is a wide range that
  holds through big moves; the **limit** is a narrower near-price band that captures everyday fee
  flow and is refilled without swapping; **idle** is the reserve held back (for example, over a
  weekend on a stock-token pool). You don't manage these; the strategy does.

- **Impermanent loss (IL).** When the two tokens in a pool change price relative to each other, an
  LP position ends up worth less than simply holding the two tokens. It is inherent to providing
  liquidity, and **FERA does not remove it**. See [Risks](risks.md#impermanent-loss).

- **Performance fee.** The **only** fee FERA charges you: **10% of the swap fees your liquidity
  collects**, and nothing on your principal, deposits, or withdrawals. If you earn no fees, FERA
  takes nothing. See the [LP guide](lp-guide.md#5-the-10-performance-fee-only-when-you-earn).

- **Early-exit window (anti-sniping guard).** A short window after each deposit (**30 min** memecoin,
  **10 min** stock-token) during which withdrawing forfeits the *fees* that position accrued in the
  window. The penalty decays to zero across the window. It **never touches principal and never blocks
  a withdrawal**. See [the early-exit window](lp-guide.md#the-early-exit-window).

- **FERA (the token).** Fixed supply, 1,000,000,000, forever. 10% at genesis (vested and
  timelocked), 90% emitted through usage only. See
  [Emissions & tokenomics](emissions-and-tokenomics.md).

- **esFERA (escrowed FERA).** How emissions arrive: non-transferable, and it **vests to FERA 1:1
  over ~6 months**. You can exit instantly for half (a 50% haircut), or wait the vest for the full
  amount. See [Rewards & vesting](rewards-and-vesting.md).

- **sFERA (staked FERA).** What you hold when you stake FERA. It gives you a boost on your own LP
  emissions (up to ~2×, a re-weighting of a fixed pool, not new tokens) and a share of protocol
  revenue. No voting, no gauges, no bribes.

- **Emissions.** FERA (delivered as esFERA) earned by vault depositors. The amount emitted each week
  can **never exceed protocol revenue** (`emitted = min(cap, β × revenue)`), so early emissions are
  small by design. Split **85% LPs / 5% traders / 10% treasury**.

- **Revenue share.** The staker's slice of FERA's real fee revenue. It is **variable and tied to
  protocol activity**, not a fixed or promised payout. We do not call it a dividend or a yield.

- **The two splits.** Don't confuse them: **85/5/10** is how *emissions* (the token) are split;
  **50/25/25** (stakers / treasury / ops) is how *revenue* (the 10% performance fee) is split.

- **Emissions cap (`min(cap, β × revenue)`).** The rule that bounds how much esFERA is minted each
  epoch. It caps the *amount emitted*, valued against real revenue; it is **not** a promised or
  bounded APR. See [Emissions & tokenomics](emissions-and-tokenomics.md).

- **TWAP (time-weighted average price).** A manipulation-resistant price averaged over a window, used
  by FERA's guards (for example, to confirm a price move is real before re-anchoring, or to sanity-
  check a deposit). It can't be pushed within a single block.

- **Oracle (Chainlink feed).** The external price reference for stock-token pools. FERA's fee logic
  fails *static* (holds position) rather than fail open if a feed is stale, and swaps never revert on
  an oracle problem.

- **Geo-fencing.** Some jurisdictions are blocked from *depositing* into stock-token pools, set by
  legal review. Swaps are never gated. See [Risks](risks.md#rwa-and-geo-fencing).

- **Epoch.** One weekly accounting period for emissions. Each epoch's rewards are computed
  deterministically and committed on-chain as a Merkle root you can recompute. See
  [Transparency](transparency.md).

- **Timelock.** A 48-hour delay on any adjustable parameter. Core economics (the 10% fee, the fixed
  1B supply, the emission bounds) are immutable and not even timelock-adjustable.
