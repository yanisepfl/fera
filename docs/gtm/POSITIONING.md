# FERA — POSITIONING

**Owner:** Agent 7 (GTM / Ecosystem). **Status:** v1 draft, gated on Pressure-Test V1–V4.
**Reads:** `docs/SHARED_CONTEXT.md`, `docs/MASTER_SPEC.md` (§4 GTM, §7 tokenomics, §13 D-M13/D-18),
`docs/RISK_REGISTER.md` (R-8, R-16, R-7).

> **Binding honesty constraints (do not violate in any asset).** These are load-bearing, not
> style notes. Every reviewer of this repo will check copy against them.
> - **D-M13 (R-16):** NEVER claim the vault out-yields a competent self-managed LP. It provably
>   does not under revenue-gated emissions (measured direct-LP fee edge 1.5–3× per dollar;
>   emissions bridge ~8% of the gap, OD-V10 resolved NEGATIVE). The vault sells *management +
>   emissions-eligibility + simplicity + risk-profile choice*, not higher yield than a pro.
> - **D-18 / R-8:** the word **"tranche" is banned in user-facing copy** (BarnBridge SEC
>   precedent, Dec 2023). Use **"risk profile"** → **"Steady"** (internal: Anchor) and
>   **"Active"** (internal: Core). Never say "dividend," "guaranteed," "fixed yield," or
>   "senior/junior." Stakers receive a *revenue share*, described as variable and activity-linked.
> - **On-chain-verifiable claims only.** Every number we publish must be reproducible by anyone
>   from the Transparency page (indexer events → Merkle bundle). If we can't point to the tx, we
>   don't say it.
> - **No paid shilling.** No paid KOL threads, no undisclosed promo, no bought "reviews."

---

## 1. The one-liner

> ## **FERA — the liquidity layer that prices what others bleed.**

Sub-line (the mechanism, in one breath):

> *A Uniswap v4 hook that charges toxic, mechanical, and weekend-arbitrage flow the fee it's
> actually worth — so the volatility that drains ordinary LPs pays FERA's LPs instead.*

Elevator (30 seconds):

> On Robinhood Chain, memecoins whip and ~95 tokenized stocks drift every weekend and snap
> back Monday. Ordinary LPs eat that as loss. FERA is a v4 hook that re-prices exactly that
> flow — high fees when flow is toxic, near-zero when it's benign — plus a managed vault so
> anyone can LP the NVDA or WETH pool without running a keeper. We don't fight bots or
> arbitrageurs; we invoice them, and the invoice goes to our LPs.

**Why this line and not a yield claim:** it describes a *mechanism that is on-chain-verifiable*
(fees scale with realized vol / oracle deviation — anyone can watch it in `beforeSwap`), and it
never promises a number. It is a wedge claim, not an APY claim. That is deliberate: our APY
edge is real but conditional (see §4a), and yield promises are the R-8 landmine.

---

## 2. The LP-first funnel thesis

FERA has exactly **one cold-start problem: TVL, not users** (SHARED_CONTEXT §4). Liquidity,
unlike attention, is *rentable with a token* — the proof is on-chain next door: **~$90M parked
in Morpho via Robinhood Earn chasing ~7%.** That capital is mercenary, on-chain, and already
comfortable with smart-contract risk. It is our beachhead.

The funnel is therefore **inverted from a normal consumer launch** — we court liquidity first,
and flow + traders arrive *because* liquidity did:

```
   LPs (deposit depth)  ──►  Depth wins router flow  ──►  Flow generates fees
        ▲                    (wave-riding, §4)            (regime-priced)
        │                                                       │
        └──────── emissions + fee yield ◄──── 85% of emissions ─┘
                  (esFERA, gated to vault shares, INV-14)
```

1. **Win depth.** Emissions (85% to LPs) + the genesis war-chest seed it (see `TVL_SEEDING.md`).
2. **Depth wins flow.** Routers (Uniswap interface, UniswapX solvers, 1inch, Rialto aggregation)
   send volume to the best *net* price. Better depth + regime-priced fees on toxic flow = better
   net price on the trades that matter. *(Load-bearing and unproven until V1/V2 — R-1.)*
3. **Flow makes fees.** Regime fees monetize the toxic/bot/weekend flow that bleeds vanilla LPs.
4. **Fees + emissions retain LPs.** The flywheel closes. Traders and the launchpad (month 3) are
   growth *modules bolted onto working liquidity infrastructure* — never the v1 wedge.

**The honest asterisk (PT-4):** depth is not a nicety, it is a *dependency*. Without a ~2–3×
depth edge, a net-price router adversely-selects — it sends the high-fee toxic swaps to the
cheaper vanilla pool and leaves us only the benign flow we price low. Fee superiority is
**necessary but not sufficient**; depth is what converts it to captured flow. Our whole GTM
budget exists to buy that depth before flow can be earned.

---

## 3. ICP (Ideal Customer Profiles), in priority order

| # | Segment | Who they are | What they want | Our hook | Reachable via |
|---|---------|--------------|----------------|----------|---------------|
| **1** | **Parked on-chain yield capital** *(beachhead)* | The ~$90M @ ~7% in Morpho/RH Earn; stable/blue-chip farmers; DeFi-native treasuries | Best risk-adjusted on-chain yield, no lockups, transparency | Managed LP with **emissions eligibility** (INV-14) + a **Steady** risk profile on RWA pairs; real yield, verifiable | DefiLlama yield page, Dune, direct DM to known farming addresses, ecosystem grants co-marketing |
| **2** | **RWA-curious / retail** | Robinhood-app-adjacent users; people who own NVDA/AAPL and now see them on-chain 24/7 | "Earn on the stocks I already believe in," one-click, no keeper | The **weekend-drift → LP income** story; single-asset deposit; Steady/Active choice; calm dark UI that "feels right for someone LPing NVDA" | The Rollup / Bankless explainer content, Robinhood-ecosystem channels, app-quality UX |
| **3** | **Degen LPs / memecoin farmers** | Already LP the top WETH/memecoin pairs; chase emissions | Highest fee capture on volatile pairs + a token to farm | The **bot-monetization** story; Active profile; MEME regime pays more the more violent the flow | Dexscreener/GeckoTerminal, memecoin Telegram/X communities (organic, not paid), farming aggregators |
| **4** | **Routers / solvers / aggregators** *(not depositors — distribution)* | UniswapX solvers, 1inch, Rialto quote-sourcing, Native | Best net price to fill against | Deep, regime-priced pools that quote well on benign flow; the 5% trader emission rebate accrues to whoever routes | Direct integration (see `ECOSYSTEM.md`); this is the V1/V2 dependency, not a marketing target |

**Segment 1 is the campaign.** Everything in `TVL_SEEDING.md` is built to move mercenary yield
capital first, because depth is the dependency for everything else. Segments 2–3 are the
narrative surface that makes the depth *sticky* and the story *tellable*.

---

## 4. The three core narratives (with honest framing)

Each narrative is a **wedge** (why FERA exists), backed by a **mechanism** (verifiable), a
**proof** (data, with its caveats stated), and a **guardrail** (the line we do not cross).

### (a) Comparative-APY — "our NVDA pool vs a vanilla pool, on the same real data"

- **Wedge:** Given the *same* position over the *same* price path, IL is identical between a
  FERA pool and a vanilla pool — so the entire difference is **fee capture**. FERA's regime fee
  captures more on the flow that matters.
- **Mechanism:** dynamic LP fee set per-swap in `beforeSwap` — MEME scales with EWMA realized
  vol [0.34%–3%, sell-side hard-max 5%]; RWA scales with |pool − Chainlink feed| [~2bp in-hours
  → 100bp closed]. Net of the immutable **10% performance fee**.
- **Proof (PRELIMINARY, synthetic — pending real-chain V4):** on violent MEME paths, regime LPs
  beat best-vanilla on **200/200 paths, mean edge +159.9%** (fee capture on the same toxic
  volume). RWA over a weekend + Monday open: **+139.7% vs a realistic vanilla-30 pool.**
- **The honest framing — this is the claim most likely to be mis-stated, so say it precisely:**
  - This compares **our pool vs a vanilla pool** (fee mechanism), **NOT** the vault vs a
    self-managed LP. A pro who self-manages a tight range still out-fees our vault ladder
    (D-M13). We never conflate the two.
  - It has **two documented holes**: (i) in genuinely *calm* MEME markets the old floor lost to
    vanilla-30 — fixed by raising the MEME floor to 0.34% (0.9 × 34bp > 30bp); (ii) the edge
    only *translates into captured flow* with a ~2–3× depth advantage (PT-4). We state both.
  - Numbers are **synthetic until Pressure-Test V4 re-runs on real chain data across ≥2 real
    weekends.** No comparative-APY number ships to the public until V4 PASSES on real data. The
    testnet demo shows the mechanism live; the mainnet numbers come with a reproducible bundle.

### (b) Weekend-drift — "your LP position earns the arbitrage now, instead of getting picked off by it"

- **Wedge:** ~95 Robinhood Stock Tokens trade 24/7 with Chainlink feeds but the underlying
  equities don't — so tokens **drift from cash price over the weekend and reconcile at Monday
  open**. That reconciliation is a recurring, structural arbitrage. For a vanilla LP it is a
  recurring, structural *loss* (they're the ones getting arbitraged).
- **Mechanism (RWA regime):** near-zero fee during market hours (keep elastic flow), a widened
  fee (30–100bp) when the market is closed, and a continuous overlay scaling with oracle
  deviation — clamped, never reverting a swap. The weekend arber pays the LP for the privilege.
- **Proof:** RWA regime converts weekend drift from LP loss into LP income; +139.7% fee edge vs
  vanilla-30 over the weekend window (synthetic; real weekend data required for V4). The flow is
  **fee-inelastic** (the arb happens regardless of fee), which is exactly why we can price it up.
- **Honest framing:** this is *recurring structural income independent of hype* (a key answer to
  R-11 volume-collapse), but it is **not** guaranteed — a quiet weekend with no drift earns
  little, and a large Monday gap still costs the position (mitigated by off-hours partial
  withdrawal q=0.60, not eliminated). We say "earns the arbitrage," never "earns you X%."

### (c) Bot-monetization — "we don't fight bots. We invoice them."

- **Wedge:** every other protocol treats wash/volume/MEV bots as a parasite to block. On an
  FCFS chain with no priority-fee auction, they're just flow. FERA prices them.
- **Mechanism (MEME regime):** the more violent/mechanical/one-sided the flow, the higher the
  fee — **wash and volume bots are fee fountains by design.** The emission math makes wash-farming
  *net-negative by arithmetic* (fee + revenue-gated rebate; trader slice cut to 5% ⇒ wash
  recovery ~500× underwater; buying FERA spot strictly dominates washing, D-M9).
- **Proof:** MEME fee superiority is driven precisely by mechanical/one-sided paths (the
  +159.9% edge lives there). V3 (bot vs organic share) informs *calibration, not viability* —
  we monetize both.
- **Honest framing:** the punchy line is true and defensible, but we do **not** imply we've
  "solved MEV" — MEV internalization (Angstrom-style top-of-block auction) is explicitly **v2
  roadmap, not v1**. v1 monetizes toxic *swap* flow via fees; it does not auction the block. Say
  "we price the flow," not "we capture the MEV."

---

## 5. Messaging house

```
                        THE LIQUIDITY LAYER THAT PRICES WHAT OTHERS BLEED
                        ─────────────────────────────────────────────────
    PILLAR 1                    PILLAR 2                      PILLAR 3
    Regime-priced fees          Managed, retail-usable        A token that can't
    (the hook)                  LP (the vault)                out-print revenue
    ─────────────────           ────────────────────          ─────────────────
    "Toxic flow is income,      "LP the NVDA or WETH pool      "Emissions ≤ what the
     not loss."                  without a keeper.              protocol actually earned."
                                 Pick Steady or Active."
    Proofs:                     Proofs:                        Proofs:
    - MEME vol→fee, live        - one-click deposit,           - β·revenue on-chain cap
      in beforeSwap               single-asset                   (INV-7), 85/5/10 split
    - RWA weekend overlay       - emissions-eligible           - no dividend / no lockup
    - 10% fee only on            (INV-14), verifiable          - Transparency page
      fees earned                                                reproduces every number
    ─────────────────────────────────────────────────────────────────────────────────
    FOUNDATION: everything is on-chain-verifiable. Wave-riding (we deploy on pairs already
    trading). No guaranteed yield. Traders & bots pay zero protocol swap fees.
```

**Proof-of-substance assets** every claim leans on: the **Transparency page** (indexer events →
weekly Merkle bundle, anyone can recompute a root), the **live comparative dashboard** (our pool
vs vanilla on the same pair, Dune), and the **testnet demo** (the mechanism visibly working
before any mainnet number is spoken).

---

## 6. Do / Don't language table

| Topic | ✅ DO say | ❌ DON'T say | Why |
|-------|----------|-------------|-----|
| Risk classes | "risk profile: **Steady** or **Active**" | "senior/junior **tranche**" | D-18 / R-8 — BarnBridge SEC (Dec 2023) attacked the *word* and the framing |
| Vault vs self-LP | "managed, emissions-eligible, one-click, choose your risk profile" | "the vault out-earns managing it yourself" / "beat the pros" | **D-M13** — provably false under revenue-gating (OD-V10); this is the top landmine |
| Staker rewards | "**revenue share** — variable, tied to protocol activity" | "**dividend**," "passive income," "yield on your stake" | R-8 — dividend language = securities exposure |
| Yield | "fees scale with realized volatility / oracle deviation" | "**guaranteed** X% APY," "**fixed** yield," "risk-free" | R-8 — no guaranteed-yield marketing, ever |
| Comparative APY | "our pool vs a vanilla pool, same path, **net of the 10% fee**, reproducible on-chain" | "FERA pays more than [named competitor]" without the bundle | Every claim must be reproducible from the Transparency page |
| Emissions | "a dividend **of activity** — emissions ≤ revenue (β-cap)" | "high APY from emissions," "farm our token for X%" | DM-2 — early usage emissions are *small*; selling emission-APR is dishonest and reflexive (R-6) |
| MEV / bots | "we **price** toxic flow," "bots pay the LPs" | "we **capture** the MEV," "MEV-proof," "we beat the bots" | MEV internalization is v2 roadmap, not v1 (SHARED_CONTEXT §2) |
| RWA | "tokenized-stock pools; **deposits are geo-fenced by config**" | "invest in NVDA," "buy stocks," "regulated" | R-8 — we provide LP infrastructure, not securities; swaps are never gated, deposits are geo-fenced |
| Routing | "routers deliver flow to the best net price; we win by depth" | "Uniswap/1inch **partners with** FERA" | R-1 unproven until V1/V2; never imply an endorsement we don't have |
| Numbers pre-mainnet | "preliminary / synthetic / pending V4 real-data confirmation" | quoting the +159.9% / +139.7% figures as live results | They are synthetic backtests until V4 PASSES on real data |
| Safety | "audited (Sherlock + boutique), bug bounty live, non-upgradeable money paths" | "safe," "can't be hacked," "risk-free" | Bunni/Gamma/Cork all shipped and still died — humility is the credible posture |

---

## 7. What we will NOT say until a gate clears

| Claim | Blocked until |
|-------|---------------|
| Any comparative-APY number as a *live result* | Pressure-Test **V4 PASS on real chain data** (≥2 real weekends) |
| "Routers auto-route to us" | **V1 + V2 PASS** (live mainnet routing test) — else it's a fallback story, not a fact |
| Anything about RWA pool *deposits* to a jurisdiction | **Legal review of RWA vaults + geo-fence list** (R-8, D-10 owner) |
| Emissions-live APR figures | The **3 D-M9 conditions** met (3 dry-run epochs, `Σleaves==emitted`, β-cap 0.9) + reproducible bundle |
| Launchpad messaging | Month-3 module ships on working infra — not part of the v1 story |

---

## SUMMARY (for the Orchestrator)

- **One-liner:** *"FERA — the liquidity layer that prices what others bleed."*
- **Funnel:** LP-first (win depth → depth wins router flow → flow makes fees → fees + emissions
  retain LPs). Beachhead = the ~$90M mercenary yield capital parked next door in Morpho/RH Earn.
- **Three narratives:** (a) comparative-APY — *our pool vs vanilla, same real data, net of fee*;
  (b) weekend-drift — *your LP position earns the Monday-reconciliation arb instead of feeding it*;
  (c) bot-monetization — *we don't fight bots, we invoice them.*
- **Honesty landmines designed around:** (1) never "vault beats self-managed LP" (D-M13); (2) no
  "tranche"/"senior/junior" → "Steady/Active" (D-18); (3) no "dividend"/"guaranteed yield" for
  stakers (R-8); (4) don't sell emission-APR as the TVL magnet (DM-2); (5) don't claim MEV
  capture in v1; (6) every number reproducible from the Transparency page or it doesn't ship.
- **Biggest positioning risk:** the comparative-APY narrative is our sharpest and our most
  fragile — it is true on violent/weekend paths but *synthetic until V4*, *holed in calm markets*,
  and *depth-gated (PT-4)*. Overstate it and we own the R-8 landmine plus a credibility crater
  when the live numbers differ. The entire copy discipline above exists to state it precisely.
