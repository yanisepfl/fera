# FERA — GTM LAUNCH CHECKLIST

**Owner:** Agent 7 (GTM). **Status:** v1 draft. **Reads:** MASTER_SPEC §11 (V1–V4 gates), §14
(Definition of Done), §15 (sequencing). Companion: `POSITIONING.md`, `TVL_SEEDING.md`,
`ECOSYSTEM.md`, `LISTINGS.md`.

> **Rule the whole checklist obeys:** GTM never opens a claim ahead of the gate that makes it
> true. Each phase's *external* actions are locked behind a *technical* gate. The gates are
> Pressure-Test / Contracts / Security owned; GTM's job is to have the assets staged so we move
> the moment a gate clears — and to **not** move before.

**Gate legend** (from MASTER_SPEC §11 / §14):
- **G-Testnet** — ≥10 MEME + ≥3 RWA pools running vault strategies **unattended 2 weeks** on
  testnet; frontend live; Transparency page + Dune up.
- **G-V1/V2** — routing verified: UniswapX/1inch fill + Uniswap interface auto-route (or fallback
  secured). Gates **mainnet deploy**.
- **G-V4** — regime LPs strictly beat vanilla on **real chain data** (≥2 real weekends), net of
  10% fee. Gates **param freeze** and **any live comparative-APY claim**.
- **G-Audit** — Sherlock contest + boutique audit done, Security written sign-off, bug bounty live.
- **G-Emissions** — 3 D-M9 conditions met (3 dry-run epochs / `Σleaves==emitted` / β-cap 0.9) +
  ≥3 consecutive clean reproducible epochs. Gates **any emission-APR number**.
- **G-Legal** — R-8 legal review of RWA vaults + staker revenue share + geo-fence list. Gates
  **RWA pool deposits**.

---

## Phase 0 — Foundations (now → testnet). No public claims.

| # | GTM action | Depends on / gate | Owner |
|---|------------|-------------------|-------|
| 0.1 | Lock positioning + do/don't language; circulate to all agents writing copy | POSITIONING.md | GTM |
| 0.2 | Route "tranche"→"Steady/Active" + staker "revenue share" language to legal | G-Legal (start) | GTM + Orchestrator |
| 0.3 | Draft grant applications (Arbitrum Open House, UF Hook Design Lab, Arbitrum Domain Allocator, Chainlink BUILD) | ECOSYSTEM.md | GTM |
| 0.4 | Spec the Dune dashboard (9 panels) + hand Backend the day-one data-ask list (L1–L6) | LISTINGS.md | GTM → Backend |
| 0.5 | **Prep the routing/allowlist packet** (pool addrs, hook bytecode + audit scope, "additive routed depth" argument) — Fallback A, weeks of lead time | R-1 / memo 01 §4 | GTM + Orchestrator |
| 0.6 | Identify + privately warm 3–5 Segment-1 anchor tenants (visible Morpho/RH-Earn farmers, DeFi treasuries) — no promises | — | GTM |
| 0.7 | Build media contact map + tailor angles per outlet | LISTINGS.md §2 | GTM |

**Exit:** all assets staged; nothing public.

---

## Phase 1 — Testnet demo (gate: **G-Testnet**). First public presence: the *mechanism*, not yields.

| # | GTM action | Gate | Note |
|---|------------|------|------|
| 1.1 | Publish **Transparency page + Dune dashboard** (testnet data) | G-Testnet | The product is the marketing |
| 1.2 | Submit grant applications; testnet run = the shared submission artifact | G-Testnet | Arbitrum Open House first (cash + routing intro) |
| 1.3 | Seed **1–2 mechanism deep-dives** (The Rollup, The Defiant) — regime hook + weekend-drift, **no yield numbers** | G-Testnet | Story = mechanism only |
| 1.4 | Open anchor-tenant diligence: hand them testnet + audit scope + Transparency page | G-Testnet | Convert to Phase-2 depositors |
| 1.5 | Publish honest tokenomics explainer (DM-2: "emissions ≤ revenue; token starts worthless; here's why that's the point") | — | Pre-empts the reflexive-APY critique |

**Do NOT yet:** quote any APY, claim routing works, claim "beats vanilla," name router "partners."

---

## Phase 2 — Routing verified + mainnet (gate: **G-V1/V2 + G-Audit + G-Legal for RWA**).

| # | GTM action | Gate | Note |
|---|------------|------|------|
| 2.1 | If G-V1/V2 = PASS → mainnet-ready. If FAIL → execute **Fallback A/B/C** *before* mainnet | **G-V1/V2** | The existential gate (R-1) |
| 2.2 | War-chest **POL seeds all ~13 pools to the 2–3× depth target** (day one) | G-Audit + G-V1/V2 | TVL_SEEDING §4 |
| 2.3 | RWA pool **deposits** open only if G-Legal clears + geo-fence live; else ship **MEME-only v1** | **G-Legal** | R-8; swaps never gated |
| 2.4 | Convert 3–5 anchor tenants into first external depositors (public, citable) | mainnet live | Credibility that pulls the next tier |
| 2.5 | News beat (The Block, DL News) with **routed-volume data** — proof the wave-riding thesis works | G-V1/V2 PASS | Real milestone, real data |
| 2.6 | List on **DefiLlama** (TVL adapter; yield adapter with `apyReward=null` pre-emissions) | Backend L1/L2/L6 | Segment-1 shop window |
| 2.7 | Ensure Dexscreener/GeckoTerminal auto-discovery (BK-2 `PoolRegistered`); claim pool profiles | Backend/Contracts L3 | Segment-3 surface |

**Do NOT yet:** publish comparative-APY as a live result (waits on G-V4); publish emission APR
(waits on G-Emissions).

---

## Phase 3 — Value-prop proven + emissions live (gate: **G-V4 + G-Emissions**).

| # | GTM action | Gate | Note |
|---|------------|------|------|
| 3.1 | **Comparative-APY panel goes public** — our pool vs vanilla, real data, net of fee, reproducible | **G-V4 PASS on real data** | Narrative (a) unlocks; the +% figures become *live*, not synthetic |
| 3.2 | Mechanism pieces citing live data (The Defiant, Blockworks/Empire) | G-V4 | Serious-outlet credibility |
| 3.3 | **Emission APR appears** on dashboards/DefiLlama — realized-only, reproducible from bundle | **G-Emissions** | `apyReward` flips from null to realized |
| 3.4 | Flywheel + retention story public (Bankless retail on-ramp; staking boost + revenue share + esFERA) | G-Emissions | "dividend of activity, ≤ revenue" framing |
| 3.5 | Weekend-drift income as recurring structural story (anti-R-11) once ≥1 real weekend of live RWA data | G-V4 + live RWA | Hype-independent income proof |
| 3.6 | Token Terminal onboarding (real revenue, real P/S) | ≥ a few epochs of revenue | Sophisticated-capital surface |

---

## Phase 4 — Broaden (month 3+).

| # | GTM action | Gate | Note |
|---|------------|------|------|
| 4.1 | Add pools on proven demand; retire under-performers (R-16 fee-share monitor) | live metrics | Data-driven pool ops |
| 4.2 | Launchpad module GTM (free launches → graduation into vault-owned locked full-range shares) | module ships on working infra | A growth module, never the wedge |
| 4.3 | Deepen staking economics narrative; multiplier points; per-pool FERA-pair emission multiplier (launchpad) | module live | Retention deepening |

---

## Standing GTM guardrails (every phase)

- **No claim ahead of its gate.** The four that most tempt over-claiming: comparative-APY (G-V4),
  routing "partnerships" (G-V1/V2), emission APR (G-Emissions), RWA deposits (G-Legal).
- **Every published number is reproducible** from the Transparency page / Merkle bundle, or it
  doesn't ship.
- **No paid shilling**, ever. "Check it yourself" (Dune + bundle) is the distribution asset.
- **Fallback A is time-critical:** the allowlist relationship has weeks of lead time — it starts
  in Phase 0, not when V2 returns FAIL.
- **The R-16 fee-share monitor is public** and watched: if vault fee-share < liquidity-share
  persistently, depositors are underperforming free-riders and will leave — that's a GTM
  early-warning, surfaced honestly, not hidden.

---

## SUMMARY (for the Orchestrator)

- **Sequence:** Phase 0 (stage everything, no claims) → Phase 1 **G-Testnet** (mechanism story,
  grants, no yields) → Phase 2 **G-V1/V2 + G-Audit + G-Legal** (mainnet, war-chest seeds depth,
  routed-volume news, DefiLlama) → Phase 3 **G-V4 + G-Emissions** (comparative-APY + emission APR
  go public, both realized/reproducible) → Phase 4 (broaden + launchpad).
- **Each external claim is locked behind the technical gate that makes it true**; the four
  highest-risk claims map to G-V4, G-V1/V2, G-Emissions, G-Legal.
- **Biggest launch-sequencing risk:** treating TVL-seeding as a post-launch growth item. PT-4
  reclassifies depth as a **V1/V2 dependency** — if we don't seed to 2–3× *before* seeking flow,
  routers adversely-select and the wave-riding thesis fails to convert even if the fees are right.
  The war-chest POL seed (Phase 2.2) must be ready to fire at mainnet, and Fallback A (allowlist)
  must already be in motion.
