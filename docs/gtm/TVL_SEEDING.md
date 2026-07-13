# FERA — TVL SEEDING CAMPAIGN

**Owner:** Agent 7 (GTM). **Status:** v1 draft, gated on Pressure-Test V1–V4 + Mechanism param
freeze. **Reads:** SHARED_CONTEXT §4, MASTER_SPEC §7 (tokenomics) / §14 (DoD), RISK_REGISTER
DM-2 / R-6 / PT-4, `docs/mechanism/*`.

> **The one thing to get right:** TVL is FERA's *only* real cold-start (SHARED_CONTEXT §4), and
> **usage emissions cannot solve it** (DM-2). The genesis war-chest seeds the initial depth; the
> campaign's job is to convert seeded depth into *mercenary-capital-attracted* depth before the
> war-chest runs down. Everything below is engineered around that, honestly.

---

## 1. The cold-start truth (DM-2) — stated before any number

Emissions are **revenue-gated**: `epoch emission ≤ min(cap(t), β × epoch revenue valued in
FERA)`, β = 0.8 (on-chain cap 0.9). Mechanism's `token_supply.py` base case shows this bound
binds so hard that **only ~11% of the 900M usage bucket actually emits over 4 years.** At
genesis, revenue ≈ 0 ⇒ emissions ≈ 0 ⇒ **early usage-emission APR is near-zero and cannot be
the TVL magnet.** The token "will be worthless at the start" (Principal, Decision-A′) — and we
say so.

**Therefore the seeding lever is the 10% genesis war-chest (100M FERA), not usage emissions.**
The war-chest is a *programmatic protocol-owned-liquidity (POL) engine* that compounds
(MASTER_SPEC §7: treasury kept at 10%, above the optimizer's 5%, precisely as the DM-2
cold-start lever). Usage emissions (85% LP / 5% trader / 10% treasury) are the **steady-state
activity dividend** that takes over once real fees flow.

**What this forbids (and we honor it):**
- ❌ No headline "farm FERA for XX% APY" — the number would be fake at launch and reflexive in a
  downturn (R-6: revenue↓→emissions↓→APR↓→TVL leaves→revenue↓).
- ❌ No fabricated APY widgets. Emissions APR is shown **only once emissions are live** (post the
  3 D-M9 conditions) and **only as realized, reproducible-from-bundle** figures.
- ✅ We market **real fee yield** (verifiable from `FeesCollected`) + **emissions-eligibility**
  (INV-14, the vault's exclusive carrot) + **management + risk-profile choice** — never a promised
  emission number.

---

## 2. Why liquidity (unlike users) is rentable — the beachhead

The proof sits on the same chain: **~$90M parked in Morpho via Robinhood Earn chasing ~7%.**
That capital is (a) already on-chain, (b) already comfortable with contract risk, (c) mercenary
and yield-seeking, (d) *addressable* — its addresses are visible on-chain. We do not need to
create demand for on-chain yield; we need to offer a better risk-adjusted home for capital that
already exists and already moves for basis points.

**The offer to that capital (honest version):** a managed LP position on a real pair with a
**Steady** risk profile, real fee yield, **plus emissions-eligibility that direct LPs don't
get** (INV-14), no lockup, and a Transparency page that reproduces every number. We do **not**
tell them it beats self-managed LPing (D-M13). We tell them it beats *leaving it idle at 7% with
no emissions and no upside*, with far less work than running their own concentrated range.

---

## 3. The launch pool set — first ~10 MEME + ~3 RWA

**Selection rule (wave-riding, SHARED_CONTEXT §4 + Mechanism pool-eligibility guardrail):** only
deploy on pairs **already trading with real volume and real volatility.** Never deploy the MEME
regime on a quiet pair — quiet MEME pools underperform even a vanilla-100bp pool (Mechanism §5).

### MEME pools (~10): pick from the top WETH / memecoin pairs by existing volume + volatility
- Criteria: existing vanilla v3/v4 depth to out-seed; genuine realized-vol (fee curve needs it);
  active organic community (narrative surface for Segment 3). WETH is ~61% of ERC-20 movement on
  the chain — WETH-quoted memecoin pairs are the volume core.
- Default single-tranche **Active** (Core) — D-16: Anchor-on-memecoins ≈ the rejected v1 product.
- Seed target: **~2–3× the incumbent vanilla pool's at-price depth** on each (PT-4 dependency).

### RWA pools (~3): flagship Stock Tokens vs USDG / WETH
- **NVDA, AAPL, GOOG** (Chainlink feeds + Proof-of-Reserve confirmed live). Highest-recognition
  names, deepest existing 24/7 flow, cleanest weekend-drift story.
- Ship **both risk profiles** (Steady + Active) — the Steady/Anchor persona is the NVDA LP (D-16).
- **Gate:** RWA pool *deposits* require the R-8 legal review + geo-fence config first. Swaps are
  never gated; deposits are geo-fenced by config (INV/FE-4). If V2 shows RWA-majors trip a
  Uniswap review (memo 01 P2 probe), we ship MEME-only v1 and add RWA post-review.

**Definition-of-done alignment (MASTER_SPEC §14):** ≥10 MEME + ≥3 RWA pools live with vault
strategies running **unattended 2 weeks on testnet** *before* mainnet seeding — the campaign
below is sequenced against that gate.

---

## 4. How the war-chest seeds depth (β-bounded, transparent, no fake APY)

The war-chest is deployed as **protocol-owned vault deposits**, not as an emissions bribe:

1. **POL as first depositor.** Treasury seeds each launch pool's vault with paired inventory
   (from the 10% genesis, vested/timelocked schedule permitting an initial tranche). This
   *is* the day-one depth that wins the first router quotes — it does not depend on emissions.
   - This also front-runs the **R-12 first-depositor / share-inflation** risk cleanly: the
     protocol is the first depositor into every pool via the virtual-shares/dead-shares mint,
     removing the griefing surface for retail deposits that follow.
2. **Depth target is explicit and measured.** Per PT-4, seed to a **~2–3× depth multiple** over
   the incumbent vanilla pool on each pair — the level at which a net-price router keeps the
   toxic flow we price high instead of adversely-selecting it away. Backend (Agent 4) tracks
   *vault-share-of-pool-fees* and *depth-vs-incumbent* as first-class metrics (R-16).
3. **Emissions layer on top, honestly.** Once revenue flows, 85% of each epoch's (β-bounded)
   emission accrues to vault shares (INV-14). This is the *retention* layer, not the acquisition
   layer. We publish realized emission APR only after it's real and reproducible.
4. **Never exceed revenue.** Emissions are structurally ≤ β × revenue (INV-7). We *say* this as a
   feature ("a dividend of activity, not a subsidy") — it is the honest counter to every
   Ponzi-emissions comparison, and it's the thing DM-2/R-6 forces us to be proud of.

**What we publish about seeding:** the POL deposits are on-chain and labeled; the depth targets
and current depth-vs-incumbent are on the Dune dashboard; there is **no** projected-APY figure
anywhere. "We seeded the depth so routers quote us; here's the live depth vs the incumbent; here's
the live fee yield" — all three are reproducible.

---

## 5. Courting the parked yield capital — the sequence

Realistic, not hype. Each phase gates on a technical milestone (see `LAUNCH_CHECKLIST.md`).

### Phase 0 — Pre-mainnet (testnet live, 2-week unattended run in progress)
- **Ship the Transparency page + comparative dashboard on testnet.** The product *is* the
  marketing: mercenary capital diligences contracts and dashboards, not threads.
- **Warm the ecosystem grants** (see `ECOSYSTEM.md`) — Arbitrum Open House / Founder House,
  Uniswap Hook Design Lab, Chainlink BUILD showcase. These fund the war-chest *and* provide
  credible third-party distribution to exactly Segment 1.
- **Private outreach, no promises.** Direct, disclosed conversations with known DeFi treasuries /
  yield desks / the visible Morpho-farming addresses: "we're launching managed LP with
  emissions-eligibility on RH Chain, here's the testnet, here's the audit scope, here's the
  Transparency page — come pressure-test it." No incentive quoted beyond "emissions-eligible +
  real fee yield."

### Phase 1 — Mainnet genesis (V1/V2 PASS, audit done, war-chest seeds depth)
- **POL seeds all ~13 pools to the 2–3× depth target** (day one, from the war-chest).
- **Anchor-tenant deposits.** Convert 3–5 of the warmed Segment-1 treasuries into first external
  depositors — reference LPs whose deposit is public and citable ("X treasury LPs the FERA NVDA
  Steady pool"). Their presence is the credibility that pulls the next tier.
- **Publish live comparative data** (only once V4 real-data PASSES): our pool vs the vanilla
  pool, same pair, net of the 10% fee, reproducible.

### Phase 2 — Emissions go live (3 D-M9 conditions met, ≥3 clean epochs)
- **Now** emissions-eligibility becomes a *number* — realized, reproducible, β-bounded. Add the
  emission APR to the dashboards (labeled realized, not projected).
- **The flywheel narrative goes public** with the media plan (`LISTINGS.md`): weekend-arb → LP
  yield, gated on the live demo and live data.
- **Retention mechanics engage:** staking (sFERA) boost on LP emissions (≤2×), revenue share
  (50% of protocol revenue to stakers), esFERA vest — all pull deposited capital toward
  stickiness. This is where the mercenary capital either compounds or churns; the RWA weekend
  income (structural, hype-independent) is the anti-churn floor (R-11).

### Phase 3 — Broaden (month 3+)
- Add pools on proven demand; launchpad module bolts on (graduation into vault-owned locked
  full-range shares). Retail (Segment 2) narrative scales via explainer content.

---

## 6. Depth-retention math the campaign must respect

- **Acquisition ≠ retention.** War-chest POL *buys* depth; it does not *keep* mercenary depth —
  emissions + real fee yield + weekend income do. If we seed to 3× and emissions are still
  ramping, expect churn; the RWA structural income and staking boost are the counterweights.
- **The reflexive trap (R-6), and our discipline around it.** In a downturn, emissions fall with
  revenue by design. If we've *marketed* emission APR, TVL bolts and accelerates the fall. Because
  we market real fee yield + weekend income + management value instead, the floor is structural,
  not sentiment. This is why the DM-2 honesty constraint is a *retention* asset, not just a
  compliance chore.
- **Watch metric (Backend):** vault fee-share-of-pool < vault liquidity-share persistently ⇒
  free-riding direct LPs are winning and depositors will leave (R-16). This is the number that
  tells us whether the seed is sticking, and it is on the dashboard.

---

## SUMMARY (for the Orchestrator)

- **Seeding lever = the 10% genesis war-chest as programmatic POL**, NOT usage emissions
  (DM-2: only ~11% of the bucket emits over 4yr; genesis-era emission APR ≈ 0).
- **Beachhead = the ~$90M mercenary yield capital** parked in Morpho/RH Earn; offer = managed +
  emissions-eligible (INV-14) + Steady risk profile + verifiable — explicitly *not* "beats
  self-managed" (D-M13).
- **Depth target = ~2–3× the incumbent** per pair (PT-4), because without it routers
  adversely-select the toxic flow we price high.
- **Pool set:** ~10 MEME (top WETH/memecoin pairs, real vol only, Active) + 3 RWA (NVDA/AAPL/GOOG,
  Steady+Active, gated on R-8 legal + geo-fence).
- **No fake APY, ever.** Emission APR appears only when realized + reproducible, after the 3
  D-M9 conditions and ≥3 clean epochs.
- **Biggest seeding risk:** war-chest buys depth but mercenary capital churns before emissions
  ramp (the DM-2/R-6 window). Mitigation = RWA structural weekend income (hype-independent) +
  staking stickiness + anchor-tenant reference LPs — and never having promised an APY that would
  make the churn reflexive.
