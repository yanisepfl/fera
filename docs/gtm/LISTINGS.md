# FERA — LISTINGS, DATA SURFACES & MEDIA PLAN

**Owner:** Agent 7 (GTM). **Status:** v1 draft. **Reads:** MASTER_SPEC §6 (event schema), §8
(indexer→API contract), §9 (emissions/Merkle). **Primary dependency:** Backend (Agent 4) — this
doc is the GTM ask list against the Backend data contract.

> **Principle:** every listing and every media claim resolves to an **on-chain-verifiable
> source**. Listings are just *distribution surfaces for the Transparency page.* If Backend can't
> serve it reproducibly, we don't list it. Media is **gated on a live testnet demo** — no story
> ships on promises.

---

## 1. Data-surface listings — what each needs from Backend (Agent 4), day one

Backend already emits the §6 events and serves the §8 API. The listing adapters are thin
translations of that. **The single most valuable day-one artifact is a public, stable, documented
read API** (TVL per pool, fee yield per pool, vault share price, emissions per epoch) — every
surface below consumes it.

### 1.1 DefiLlama — TVL adapter + yield adapter (highest priority)

DefiLlama is where Segment-1 mercenary capital shops for yield. Two separate adapters:

**(a) TVL adapter** (`DefiLlama-Adapters` PR):
- Needs from Backend: per-pool **token balances held by the Vault** (the sole position owner),
  resolvable from chain state at a block. Adapter sums vault-held `token0`/`token1` across all
  pools × Chainlink/feed USD price. Must **exclude double-counting** (vault owns the v4 position;
  don't also count the raw pool).
- Backend deliverable: a documented `GET /tvl` (per-pool + total, USD, block-stamped) **and** the
  canonical Vault address list so the adapter can read balances directly on-chain (DefiLlama
  prefers on-chain reads over trusting an API).
- Category: "Liquidity Manager" / "DEX" — **not** "Yield Aggregator" (avoid the tranche/structured
  framing, R-8). Chain: Robinhood Chain (ensure DefiLlama lists chain 4663; may need a chain PR).

**(b) Yield adapter** (`yield-server` PR — the DefiLlama "Pools"/APY page):
- Needs from Backend, **per pool + per risk profile (Steady/Active)**:
  - `apyBase` = **realized fee yield** (annualized from `FeesCollected` net of the 10% perf fee) —
    trailing-window realized, never projected.
  - `apyReward` = **realized emissions APR** valued at FERA TWAP — **populated only after
    emissions go live** (post D-M9 conditions). Until then: `apyReward = null`, not 0-as-teaser.
  - `underlyingTokens`, `rewardTokens` (FERA), `tvlUsd`, `pool` (id), `symbol`.
  - **`il7d` / notes:** surface IL honestly where the schema allows.
- **Honesty gate:** `apyReward` must be **realized + reproducible from the Merkle bundle**, never a
  forward emission projection (DM-2, R-8). This is the one field most likely to become a landmine —
  Backend must serve realized-only.

### 1.2 Dexscreener / GeckoTerminal — pool discovery + charts (Segment 3 surface)

- These auto-index DEX pools from on-chain events; **primary need is that our pools are
  discoverable as standard v4 pools.** Ties directly to **V2** (if the interface/indexers don't
  see flagless hooked pools, neither do these — same root risk as R-1).
- Backend/Contracts deliverable: ensure pool-init is indexable — the proposed **`PoolRegistered`
  event** (BK-2: `poolId → {token0, token1, decimals, regime}`) makes our pools self-describing to
  any third-party indexer instead of env-sourced. **GTM ask: prioritize BK-2** so Dexscreener/GT
  pick us up without a manual submission.
- Manual submission: claim/enhance the token+pool profile (logo, socials, description) once live —
  free, self-serve. Use "risk profile: Steady/Active," never "tranche."
- GeckoTerminal → CoinGecko on-chain DEX data path: same indexing; good for the FERA token page
  later.

### 1.3 Dune dashboard — the public Transparency + comparative surface (GTM owns the spec)

The Dune dashboard is our **flagship credibility asset** — it's where every media claim and every
listing number is independently checkable. Built on the same §6 events (Dune can read RH-Chain
logs; if chain 4663 isn't yet in Dune's ingested set, that's a required prerequisite — verify /
request early).

**Dashboard spec (panels):**
1. **TVL** — total + per pool + per risk profile, time series.
2. **Depth vs incumbent** — our at-price depth ÷ the competing vanilla pool's, per pair (the PT-4
   metric; proves the wave-riding wedge is working).
3. **Comparative fee capture** — *our pool vs a vanilla pool, same pair, same window, net of the
   10% fee* — the narrative (a) proof, **only shown once V4 real-data PASSES.**
4. **Realized fee yield** per pool/profile (from `FeesCollected`), trailing windows.
5. **Regime fee live** — current dynamic fee vs realized vol (MEME) / oracle deviation (RWA) — the
   mechanism visibly working; the "prices what others bleed" one-liner made watchable.
6. **Weekend-drift panel** — RWA pool price vs Chainlink feed + fee overlay across the weekend +
   Monday open; fees earned on the reconciliation (narrative (b) proof).
7. **Emissions** — per epoch: `cap(t)`, `β × revenue`, actual emitted, 85/5/10 split, and the
   `Σleaves == emitted` check (INV-7 / R-19 made public). "Emissions ≤ revenue" as a live chart.
8. **Vault fee-share-of-pool vs liquidity-share** — the R-16 monitor, public. Radical honesty:
   we show the metric that would reveal if depositors are underperforming free-riders.
9. **Bot/toxic-flow monetization** — fees earned attributable to one-sided/mechanical flow
   (narrative (c) proof).

**Backend ask:** either Dune ingests chain 4663 natively (verify), or Backend runs a
**Dune-uploadable table** (via the reproducible bundle) so the dashboard has a source. The
dashboard queries must be **forkable/public** — reproducibility is the whole point.

### 1.4 Token Terminal — protocol financials (post-emissions / fundraise-facing)

- Consumes: protocol **revenue** (the 10% perf fee take), **fees** (gross LP fees), TVL, token
  supply/emissions, treasury. All derivable from §6 events + §9 emissions data.
- Backend ask: a stable `GET /metrics/financials` (or the bundle) exposing gross fees, protocol
  revenue, RevenueDistributor splits (50/25/25), emissions valued at FERA TWAP, circulating vs
  emitted supply.
- Timing: **after** emissions live + a few epochs of real revenue — Token Terminal is for the
  "real revenue, real P/S" story to sophisticated capital + potential investors, not launch day.
- Honesty: revenue is real (fee on fees earned), never inflated by counting emissions as revenue.

### Backend day-one deliverable checklist (the GTM ask, consolidated)

| # | Deliverable | Consumes | Feeds | Priority |
|---|-------------|----------|-------|----------|
| L1 | Public documented read API: `/tvl`, `/pools` (fee yield, share price, per profile) | §8 | DefiLlama, everything | **P0** |
| L2 | Realized `apyBase` + **realized-only** `apyReward` (null pre-emissions) | §8/§9 | DefiLlama yield | **P0** |
| L3 | `PoolRegistered` event so pools self-describe to third-party indexers (BK-2) | §6 | Dexscreener/GeckoTerminal | **P0** (Contracts) |
| L4 | Reproducible bundle → Dune-uploadable tables (or confirm Dune ingests 4663) | §9 | Dune dashboard | P1 |
| L5 | `/metrics/financials` (gross fees, protocol revenue, splits, emissions) | §6/§9 | Token Terminal | P2 (post-emissions) |
| L6 | Canonical Vault address list + chain-4663 registration on DefiLlama/Dune | — | TVL adapter, Dune | **P0** |

---

## 2. Media plan

**Thesis of the pitch:** the **weekend-arb → LP-yield** story (narrative b) is the most novel,
most legible, most on-chain-verifiable, and least degen-coded angle — it travels to serious
outlets. The bot-monetization line (narrative c) is the memorable hook for the crypto-native
outlets. **Every pitch is gated on a live testnet demo + the Dune dashboard** — no embargoed
promises, no numbers we can't reproduce.

### Angle by outlet

| Outlet | Lens | Lead angle | Gate |
|---|---|---|---|
| **The Defiant** | DeFi mechanism / yield | "Tokenized-stock weekend drift used to bleed LPs; this v4 hook turns it into LP income" (narrative b) | Live testnet demo + RWA weekend panel |
| **Blockworks / Empire (pod)** | Markets + structure | The RWA-arb structural-income thesis; wave-riding on Robinhood Chain; the tokenomics that can't out-print revenue | Testnet demo; founder on-pod |
| **Bankless** | Retail-DeFi education | "LP the NVDA pool without running a keeper" — Steady/Active, one-click, the retail on-ramp (Segment 2) | Live product + explainer |
| **DL News** | News + a little edge | Bot-monetization line ("we don't fight bots, we invoice them", narrative c) + the honest DM-2 tokenomics | Testnet demo |
| **The Block** | Straight news / data | Launch on Robinhood Chain; TVL + routed-volume data once V1/V2 PASS; measured, sourced | Mainnet + V1/V2 PASS + Dune |
| **The Rollup** | Ecosystem / builder pod | Deep-dive on the regime hook + RH-Chain ecosystem; the Uniswap-hook novelty | Testnet demo; technical walkthrough |

### Sequencing (tied to gates — see `LAUNCH_CHECKLIST.md`)
1. **Testnet demo live + Dune up** → seed 1–2 mechanism deep-dives (The Rollup, The Defiant) —
   *story is the mechanism*, no yield numbers yet.
2. **V1/V2 PASS + mainnet** → news beat (The Block, DL News) with **routed-volume data** (proof the
   wave-riding thesis works) — the real milestone, real data.
3. **V4 real-data PASS** → the comparative-APY panel goes public; The Defiant / Blockworks
   mechanism pieces can now cite live pool-vs-vanilla data.
4. **Emissions live (post D-M9)** → the flywheel + tokenomics story (Blockworks/Empire, Bankless
   retail on-ramp), always framed as "dividend of activity, ≤ revenue."

### Media do/don't (mirrors POSITIONING §6)
- ✅ Offer journalists the **Dune dashboard + the reproducible bundle** — "check it yourself" is
  our strongest media asset and it's rare.
- ✅ Lead with mechanism + structural income; concede the caveats (synthetic-until-V4, depth
  dependency, calm-market hole) — credibility with serious outlets *is* the honesty.
- ❌ No paid placements, no paid KOL threads, no embargoed APY numbers, no "partnered with
  Uniswap/1inch" (R-1 unproven). No "invest in stocks" / securities framing on RWA (R-8).
- ❌ Don't pitch the launchpad as the story — it's a month-3 module on working infra.

---

## SUMMARY (for the Orchestrator)

- **Listings are distribution surfaces for the Transparency page.** Day-one Backend asks (P0):
  public read API (`/tvl`, `/pools`); **realized-only** `apyBase`/`apyReward` (null pre-emissions —
  the key honesty gate); `PoolRegistered` event (BK-2) so third-party indexers auto-discover us;
  canonical Vault address list + chain-4663 registration. Dune dashboard (GTM-spec'd, 9 panels
  incl. the self-incriminating R-16 fee-share monitor) is the flagship credibility asset. Token
  Terminal is post-emissions.
- **Media pitch = weekend-arb→LP-yield (serious outlets) + "we invoice the bots" (crypto-native),
  gated on a live testnet demo + Dune** — no promised numbers, "check it yourself" as the asset.
- **Biggest listings risk:** the `apyReward` field — if Backend ever serves a *projected* emission
  APR, DefiLlama surfaces it to exactly the mercenary audience and we own both the DM-2 dishonesty
  and the R-8 landmine. Realized-only, reproducible-only, or null. Non-negotiable.
