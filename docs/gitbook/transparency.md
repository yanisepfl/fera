# Transparency — every number is reproducible on-chain

FERA's core promise about *numbers* is simple: **if we show it to you, you can recompute it yourself
from public data.** Nothing on the site is a projection you have to take on faith, and there is no
off-chain "projected APY" without a formula you can check. This page explains how that works, so you
can verify us instead of trusting us.

## The chain of custody, from swap to screen

1. **Everything starts as an on-chain event.** Every swap emits an event with the fee paid. Every
   time the vault collects fees, that's an event. Deposits, withdrawals, share-price checkpoints, and
   strategy actions are all events. These are public and permanent.
2. **An indexer reads those events** and serves them through a public data API. The site reads *only*
   this API for lists and aggregates — it doesn't invent numbers.
3. **Once a week, emissions are computed deterministically** from a frozen snapshot of that epoch's
   events, and the result is committed on-chain as a single **Merkle root**. You then claim your
   esFERA against that root.
4. **The computation is reproducible.** For each epoch, FERA publishes a **reproducibility bundle**:
   the exact input snapshot (the event dump, the block range, the price-oracle inputs, and the data
   used to exclude self-dealing flow), the open-source script that computes the root, and its version
   hash. Anyone can re-run the script on the snapshot and get the *identical* root. If they don't
   match, the posted root is wrong — and that's checkable by anyone, not just FERA.

The emissions pipeline is designed so that a posted epoch is **never hotfixed**: once a root is on
chain it is immutable, and the on-chain distributor caps total claims at exactly the funded amount,
so a compromised poster cannot exceed the envelope.

## What you can verify

- **Fee yield.** Add up the fee events for a pool; that's the gross fee income. The 10% performance
  fee and your pro-rata share follow from public share balances.
- **Emissions.** Re-run the published script on the epoch snapshot; confirm the Merkle root matches
  what's on-chain; confirm your leaf is in the tree.
- **The emissions cap.** The Transparency page plots the supply cap, the revenue bound (`β × revenue`,
  β = 0.8), and what was actually emitted. Emitted can only ever be the *lower* of the two bounds —
  you can see the gate hold, epoch by epoch. (See [Emissions](emissions-and-tokenomics.md).)
- **The two splits.** The **85/5/10** emission split and the **50/25/25** revenue split are both
  shown, side by side, and never conflated. Each is backed by an on-chain invariant test — for
  example, revenue is split with no rounding dust escaping.
- **The performance fee.** It is exactly 10% of collected LP fees, 0% of principal, on every path —
  an invariant, not a policy.

## What we will *not* show you (until it's earned)

Transparency cuts both ways — it also means **not** publishing numbers we can't yet stand behind:

- **Comparative-APY claims** ("our pool vs a vanilla pool") are, until independently verified on real
  chain data across at least two real weekends, **synthetic backtests** — and we label them as such.
  No comparative number ships as a *live result* before that verification passes.
- **"Routers auto-route to us"** is a mechanism we expect, not a partnership we have. Until it's
  demonstrated live on mainnet, it's a hypothesis, and we say so.
- **Emissions-live APR figures** wait for the reproducibility conditions above to be met on mainnet.

## Why this matters

Protocols that shipped and still failed — Bunni, Gamma, Cork — all had confident dashboards. FERA's
posture is the opposite of "trust us": the whole point of publishing the events, the script, and the
version hash is so you *don't* have to. The contracts are backed by a rigorous internal
[security review](security.md) and non-upgradeable money paths; the reproducibility bundle backs the
numbers.

---

Next: [Security →](security.md) · [FAQ →](faq.md) · [Risks →](risks.md)
