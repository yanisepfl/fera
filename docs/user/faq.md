# FAQ

Short answers. Each links to the fuller explanation.

### What does FERA actually do?
It provides liquidity on Robinhood Chain with a **smart, market-aware swap fee** (higher when flow
is toxic, near-zero when it's benign) plus a **managed vault** so you don't have to run anything.
[What is FERA?](./what-is-fera.md)

### What does it cost me?
A **10% performance fee on the swap fees your liquidity earns** — and nothing else. No fee on your
deposit, your withdrawal, your principal, or on any swap. If you earn no fees, FERA takes nothing.
[Details.](./lp-guide.md#5-the-10-performance-fee--only-when-you-earn)

### Is there a guaranteed yield?
**No.** FERA never promises an APY. What you earn depends on the volume and volatility your pool
sees. The fee scales with market conditions; it does not scale to a target. [Risks.](./risks.md#no-guaranteed-yield)

### Does FERA remove impermanent loss?
No. Impermanent loss is inherent to providing liquidity, and FERA doesn't change it — over the same
price path, your IL is the same as in a vanilla pool. FERA changes **fee capture**, not IL.
[Details.](./lp-guide.md#4-fees-vs-impermanent-loss--the-honest-version)

### Steady or Active — which do I pick?
**Active** = concentrated near price, more fees, more IL. **Steady** = wide, steadier, less of both;
built for conservative exposure (e.g. LPing a stock token). Memecoin pools offer Active only.
[Details.](./lp-guide.md#2-steady-vs-active--choosing-a-risk-profile)

### Can I withdraw any time?
Yes — withdrawals are **never blocked or paused**, and your principal comes back in full. If you
withdraw within a short window of depositing (30 min for memecoin pools, 10 min for stock-token
pools), you forfeit the *fees* accrued in that window; the penalty decays to zero over the window
and never touches principal. [Details.](./lp-guide.md#the-early-exit-window)

### Why did I forfeit fees when I withdrew quickly?
That's the early-exit guard — it stops bots from sniping high-fee moments. Those forfeited fees are
donated to the providers still in range (so when others do it, *you* get paid). [Details.](./lp-guide.md#the-early-exit-window)

### Why are my emissions so small?
By design. Emissions are capped by real revenue (`emitted = min(cap, β × revenue)`), and a young
protocol earns little, so early emissions are small. FERA doesn't sell an emissions APR.
[Emissions.](./emissions.md#the-honest-asterisk-early-emissions-are-small)

### Why is my esFERA locked, and what's the 50% haircut?
Emissions arrive as **esFERA**, which vests to FERA 1:1 over ~6 months. You *can* exit instantly,
but only for half — the other half is forfeited (1/3 burned, 1/3 to vesting stakers, 1/3 to
revenue). Waiting is usually the better deal. There's a live calculator before you confirm.
[Rewards & vesting.](./rewards-and-vesting.md#the-instant-exit-haircut-in-numbers)

### What do I get for staking?
Up to ~2× boost on **your own LP emissions**, a **share of protocol revenue** (variable, not a
dividend), and an optional time-lock. No voting, no gauges, no bribes. [Details.](./rewards-and-vesting.md#staking-sfera)

### Does the vault out-earn managing my own position?
**No, and we won't claim it does.** A skilled provider hand-managing a tight range typically
captures more fees per dollar. The vault sells management, emissions-eligibility, simplicity, and a
risk-profile choice — not higher yield. [Details.](./lp-guide.md#7-lp-directly-vs-the-vault-open-liquidity)

### Can anyone provide liquidity, or only through the vault?
Anyone can LP a FERA pool directly and permissionlessly (pick your own range, full control). Only
**vault** deposits earn FERA emissions, though. [Details.](./lp-guide.md#7-lp-directly-vs-the-vault-open-liquidity)

### Is this "investing in NVDA" or buying stocks?
No. FERA is liquidity infrastructure, not securities. Deposits to stock-token pools are geo-fenced
by jurisdiction; swaps are never gated. [Risks.](./risks.md#rwa-and-geo-fencing)

### Do traders or bots pay FERA a fee?
No protocol fee, ever, on any swap — and swaps are never blocked. The dynamic fee is entirely the
liquidity providers'. FERA prices toxic flow; it does not "capture MEV" (that's a v2 idea, not a v1
claim). [What is FERA?](./what-is-fera.md#what-fera-is-not)

### How do I know the numbers are real?
Every number is reproducible from on-chain events; emissions are computed by an open-source script
against a published snapshot and committed as a weekly Merkle root you can recompute.
[Transparency.](./transparency.md)

### Is FERA audited?
Yes — a Sherlock contest plus a boutique review, with a live bug bounty and non-upgradeable
money-path contracts. That reduces risk; it does not remove it. [Risks.](./risks.md#smart-contract-risk)
