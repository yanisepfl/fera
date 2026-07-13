# FERA — ECOSYSTEM PROGRAMS & INTEGRATION RELATIONS

**Owner:** Agent 7 (GTM). **Status:** v1 draft. **Reads:** SHARED_CONTEXT, MASTER_SPEC §11
(V1/V2 gate), RISK_REGISTER R-1 (routing existential). **Web-sanity-checked 2026-07-12** — every
program below was verified to exist/be current this session; confidence tags inline.

> Two distinct workstreams live here: **(A) grants & programs** — non-dilutive capital and
> credible third-party distribution that *funds the war-chest and reaches Segment 1*; and
> **(B) router/aggregator relations** — the **V1/V2 routing dependency (R-1)**, which is
> *distribution infrastructure, not competition*, and gates mainnet. Do not conflate them: a
> grant is nice-to-have; routing is existential.

---

## A. Grant & accelerator programs (ranked by fit)

### A1. Arbitrum Open House 2026 + Founder Houses — **BEST FIT** · confidence **HIGH**

- **What it is (verified):** Arbitrum's global founder-enablement program — virtual workshops,
  regional **Buildathons** (NYC, London, Singapore, Dubai), and in-person **Founder Houses**.
  **Robinhood Chain is a headline sponsor, committing $1M in prizes** specifically to back teams
  building on the **Robinhood Chain testnet and future mainnet.** NYC Founder House concluded with
  **$340K** awarded; OH London earmarked **~$415K**; total program **~$1.8M** in prizes.
- **Why we fit (better than almost any other applicant):** FERA is a native Robinhood-Chain DeFi
  primitive that *only makes sense on this chain* (regime fees exploit RH Stock Tokens'
  weekend-drift + the memecoin flow). This is exactly the "programmable economy / RWA + tokenized
  finance" thesis the program is funding. The $1M is Robinhood's money aimed at its own chain's
  ecosystem — we are the target applicant.
- **The ask:** Buildathon/Founder House prize + follow-on Arbitrum support; testnet-demo track
  (our 2-week unattended testnet run doubles as the submission). Secondary ask: warm intro to the
  Robinhood Chain / Arbitrum Foundation ecosystem team for the **routing/allowlist conversation**
  (Fallback A, see §B) — the single most valuable non-cash outcome.
- **Timing:** apply into the next Buildathon/Founder House cohort; aligns with our testnet gate.
- **Sources:** [Robinhood Chain testnet + $1M](https://blog.arbitrum.io/robinhood-chain-testnet/),
  [NYC Founder House $340K](https://blog.arbitrum.foundation/nyc-founder-house-concludes-with-340k-in-awards-to-winning-teams/),
  [Open House](https://openhouse.arbitrum.io/),
  [Robinhood $1M announcement](https://x.com/RobinhoodApp/status/2021600209524969824).

### A2. Arbitrum Foundation grants + Questbook / Domain Allocator Offerings — confidence **HIGH**

- **What it is (verified):** the Arbitrum DAO's milestone-based grants, run through
  **"Domain Allocator Offerings" (formerly Questbook)** — community-elected allocators fund
  domain-specific work (dev tooling, new protocols, education, gaming). ~$1M program, ~$200K per
  domain, milestone-gated.
- **Why we fit:** FERA is new DeFi infrastructure + open-source tooling (a reusable v4 regime
  hook, an indexer/emissions pipeline) on Arbitrum-stack rails. The **dev-tooling / new-protocol**
  domains are the fit; the reproducible emissions bundle + Transparency page are grant-legible
  public goods.
- **The ask:** a milestone grant tied to shippable public-good artifacts (open-sourced hook +
  audit, the reproducible Merkle/indexer bundle). Keep it non-dilutive; do **not** frame around
  token emissions (DM-2 honesty + R-8).
- **Confidence caveat:** program is live and active in 2026 (recent domain reports dated 2026),
  but allocator rosters/budgets rotate quarterly — confirm the current open domain + allocator
  before applying.
- **Sources:** [Arbitrum Grants](https://arbitrum.foundation/grants),
  [Domain Allocator (prev Questbook)](https://www.arbitrumhub.io/grant-hub/quest-book/).

### A3. Uniswap Foundation — Hook Design Lab / Hook Incubator grant — **STRONG FIT** · confidence **HIGH**

- **What it is (verified):** the UF funds v4 hook builders — grants **$7.5K to $1M+**; **Hook
  Design Lab** (pilot: technical mentorship + **go-to-market strategy** + milestone funding +
  ecosystem alignment) and the async **Hook Incubator**. UF committed **$26M in grants in 2025**,
  funded into 2027, 1,000+ hooks initialized.
- **Why we fit (novelty is the pitch):** FERA's hook is a **genuinely novel regime primitive** —
  volatility-EWMA dynamic fees + a Chainlink-oracle-deviation RWA overlay + an OZ-pattern
  fee-forfeiture JIT guard, all flagless (auto-routable) with a ≤40k gas swap path (measured
  ~15.1k). That is exactly the "frontier DeFi infrastructure" the Design Lab exists for, and few
  applicants bring a hook this economically substantive with a security loop already converged.
- **The ask:** Design Lab cohort spot for **mentorship + GTM support + milestone funding**; the
  GTM support is arguably worth more than the cash (UF distribution into the v4 builder + LP
  audience is Segment-1/3 reach we can't buy). Open-source the hook to qualify.
- **Confidence caveat:** the specific sub-program (Design Lab vs Incubator vs open grants) and its
  intake window rotate — confirm which is open at apply time.
- **Sources:** [UF Grants](https://www.uniswapfoundation.org/grants),
  [Hook Design Lab](https://www.uniswapfoundation.org/blog/introducing-the-uniswap-v4-hook-design-lab),
  [get funded](https://developers.uniswap.org/docs/ecosystem/builder-support/get-funded).

### A4. Chainlink BUILD — showcase feed consumer — confidence **MED** (program in transition)

- **What it is (verified, with a caveat):** Chainlink's ecosystem program for aligned projects —
  technical support from Chainlink Labs, curated resources, and **exposure/co-marketing** (BUILD
  projects are regularly highlighted at events + on Chainlink channels). **IMPORTANT — the
  program is mid-restructure:** it is **moving away from project-token rewards toward commercial
  agreements paid in LINK**, and legacy **Build Rewards token claims ended July 7, 2026.** So
  pursue BUILD for **technical support + exposure + oracle showcase**, NOT for token rewards.
- **Why we fit:** FERA is a heavy, *showcase-grade* Chainlink consumer on a chain where Chainlink
  is the official oracle infra — RWA band-centering + the fee-deviation overlay read **Data
  Feeds** (Data Streams as a v2 path), and the pools ride **Proof-of-Reserve-backed** Stock
  Tokens. "Chainlink feeds turn tokenized-stock weekend drift into LP income" is a clean oracle
  case study Chainlink marketing wants.
- **The ask:** BUILD membership for **technical support + co-marketing / case-study**; explicitly
  frame as an oracle-showcase, not a rewards grab. Cross-list the FERA×Chainlink case study with
  the RWA media angle (`LISTINGS.md`).
- **Confidence caveat:** because the rewards model is changing, treat cash/token expectations as
  LOW; treat exposure/technical-support value as MED-HIGH. Re-verify the current intake form.
- **Sources:** [BUILD evolution](https://chain.link/blog/build-program-evolution),
  [rewards shift to LINK](https://blockonomi.com/chainlink-build-program-shifts-rewards-from-project-tokens-to-link-payments),
  [BUILD program](https://chain.link/blog/chainlink-build-program).

### Grant workstream summary

| Program | Fit | Confidence | Primary value | Non-dilutive? |
|---|---|---|---|---|
| Arbitrum Open House / Founder House ($1M RH) | **Best** | HIGH | Prize cash → war-chest + RH ecosystem intro (routing) | Yes |
| Arbitrum Foundation / Domain Allocator | Strong | HIGH | Milestone grant for open-source public goods | Yes |
| Uniswap Foundation Hook Design Lab | Strong | HIGH | Cash + **GTM support + v4 distribution** | Yes (open-source hook) |
| Chainlink BUILD | Good (showcase) | MED (in transition) | Technical support + co-marketing exposure | Exposure, not tokens |

**Sequencing:** warm all four during the **testnet phase** (Phase 0 in `TVL_SEEDING.md`) — the
2-week unattended testnet run + Transparency page is the shared submission artifact for all of
them. Arbitrum Open House is the top priority (biggest cash + the routing intro).

---

## B. Router / aggregator relations — **distribution, not competition** (the V1/V2 dependency)

**This is the existential one (R-1).** FERA's wave-riding thesis assumes external routers deliver
volume to our pools when our net price is best. **If they don't, we have depth but no flow and
the thesis collapses** (memo 01). The hook is deliberately flagless (open swaps, no sender gate)
to land in the "auto-allowlist lane" — but *whether that holds on Robinhood Chain is unverified
and gates mainnet.* Relations here are the mitigation + fallback stack.

**Mental model:** routers and aggregators are **our distribution channel**, not rivals. Rialto
"competing" as a prop-AMM with built-in quote aggregation is *good for us* — its aggregation is
another mouth that can quote our depth. We win by being the best net price *inside* their routing,
not by taking their users.

| Counterparty | Role | Our relationship = | V1/V2 tie | Action |
|---|---|---|---|---|
| **Uniswap interface / routing API** | Primary public AMM UI on RH Chain; auto-routing | Get auto-indexed as a flagless dynamic-fee pool | **V2** (interface inclusion ≥80%) | Verify auto-index in the V1/V2 live test; if not, **Fallback A** allowlist ask (prep the packet *now*: pool addrs, hook bytecode + audit, "additive routed depth, no swap protocol fee" argument) |
| **UniswapX solvers** | Off-chain solvers fill Dutch/RFQ orders | Be a fillable source within gas budget | **V1** (fill-rate ≥50%) | Test solver fills; **Fallback C** = run our *own* UniswapX filler sourcing from our pools (also the v2 MEV-internalization asset) |
| **1inch (RH-Chain router)** | Dominant aggregator | Be included when best price | **V1** (inclusion ≥50%) | Test inclusion; **Fallback B** = register as a PMM/AMM liquidity source via a Backend quote adapter |
| **Rialto** | Prop-AMM spot **with built-in quote aggregation** | Quote-sourcing = *free distribution* | reinforces V1 | Offer our pools as a quote source to Rialto's aggregation — distribution, not a turf fight |
| **Native** | Execution / PMM layer | RFQ source | reinforces V1 | Stand up an RFQ endpoint (Backend); first-class PMM source, aggregator-independent |

**The V1/V2 verification gate (Pressure-Test 8 owns; GTM co-owns the fallbacks):**
- **V1** — do UniswapX solvers + 1inch route/fill to a flagless hooked v4 pool when we're best
  price, within the ≤40k gas budget? **Gates mainnet deploy.**
- **V2** — does the Uniswap interface auto-route us, and do RWA-majors (NVDA) trip a review? Our
  P2 probe pool (memo 01) surfaces the RWA-review path early. **Gates mainnet deploy.**

**GTM-owned fallbacks (build in parallel, don't discover at mainnet — memo 01 §4):**
- **Fallback A (GTM + Orchestrator):** the **allowlist conversation** with Uniswap Labs / the
  interface + the Robinhood-Chain ecosystem team. Lead time = weeks → **start at deploy, not at
  FAIL.** The Arbitrum Open House / RH-ecosystem intro (A1) is the warm path into this.
- **Fallback B/C:** direct aggregator integration (1inch/Native/Rialto quote adapter) and running
  our own UniswapX filler — engineering-owned, but GTM owns the *relationships* that make them land.

**Why this belongs in GTM, not just engineering:** the difference between "flagless hook
auto-routes" and "we need an allowlist PR / a direct integration" is a *relationship + a packet*,
and the lead time is weeks. If R-1 resolves FAIL, our entire launch depends on a conversation we
should already be having.

---

## SUMMARY (for the Orchestrator)

- **Grants (all verified live 2026-07-12):** (1) **Arbitrum Open House / Founder House** — best
  fit, HIGH confidence, Robinhood's own $1M aimed at RH-Chain builders, doubles as the warm intro
  to the routing/allowlist team; (2) **Arbitrum Foundation / Domain Allocator** — HIGH, milestone
  grant for open-source public goods; (3) **Uniswap Foundation Hook Design Lab** — HIGH, novel
  regime hook + UF GTM distribution; (4) **Chainlink BUILD** — MED, oracle showcase for
  exposure/support, **not** token rewards (program mid-restructure, legacy rewards ended
  2026-07-07). Warm all four during the testnet phase off one shared artifact.
- **Routing = the existential dependency (R-1), framed as distribution not competition.** Routers
  (Uniswap interface, UniswapX, 1inch) and quote-aggregators (Rialto, Native) are our channel;
  V1/V2 gate mainnet. GTM owns **Fallback A (allowlist conversation)** — start it at deploy.
- **Biggest ecosystem risk:** R-1 — if flagless-hook auto-routing FAILS on RH Chain, launch hinges
  on the allowlist relationship + direct integrations, whose lead time is weeks. The Open House /
  RH-ecosystem intro is the mitigation, and it must be initiated before we know the V1/V2 verdict.
