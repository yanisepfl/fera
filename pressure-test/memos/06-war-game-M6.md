# Memo 06 — M6 Competitive & Macro War Game

**Verdict: CONDITIONAL (survivable).** FERA survives each shock, but two of them
(fast-follower fork + a Uniswap v4 protocol fee) attack the value capture directly and dictate
what the moat must actually be: **depth + token flywheel + data/ops, NOT the hook code.** For
each scenario: what survives, the counter, and what to build differently NOW.

## Scenario 1 — Arrakis (or a fork) copies the regime-fee hook

**Threat.** The hook is on-chain, unlicensed-copyable Solidity. Arrakis is the closest analog
(issuer-facing ALM) and could ship a "dynamic-fee vault" in weeks; a nameless fork could do it
in days. Regime fees are not a defensible secret.

**What survives.** The hook is the *least* defensible layer; the moat is everything the fork
can't copy cheaply: (a) **depth** — routed flow follows the deepest best-net-price pool, and depth
is bought with the emission flywheel + accumulated TVL, which a fork must bootstrap from zero;
(b) the **calibrated fee curve + quality score** (memo 02/03), which needs real chain-flow data
we will have and they won't; (c) **retail-LP UX + the vault-share composability funnel**; (d)
brand/integration with routers (the V1/V2 allowlist relationship, memo 01).

**Counter.** Win the land grab: seed the top pairs first and get routed volume + TVL before a
fork exists (first-mover depth compounds via emissions). Make the token flywheel real early so
LP capital is stickier than rented. Keep the fee curve improving from live data — a moving target.

**Build differently NOW.** (i) Prioritize **depth-seeding and the emission flywheel as V1**, not
month-3 (reinforces memo 03 PT-4). (ii) Instrument the flow census (memo 02) from day one so our
fee calibration stays ahead. (iii) Don't burn the differentiation on the hook; put it in
calibration + data + UX.

## Scenario 2 — Uniswap activates a v4 protocol fee

**Threat.** v4 `PoolManager` supports a protocol fee (a cut of swap fees, governance-set,
currently off). If Uniswap governance turns it on chain-wide, it taxes **swap fees on every v4
pool including ours** — reducing what reaches LPs and compressing our LP-superiority margin.

**What survives.** Our value prop is *relative* (LPs earn more **per dollar** than any
alternative). A protocol fee hits our pools **and** every vanilla v4 pool **equally**, so the
*relative* superiority is preserved. It does compress the absolute LP yield and stacks on our
10% perf fee, worsening the memo 03 calm-market hurdle (perf fee + protocol fee both eat the
thin floor margin).

**Counter.** The regime fee can **absorb** a protocol fee by raising the fee curve so
net-to-LP is held constant (we price toxicity; we have headroom to the ceiling that a static
vanilla pool does not). Model the protocol fee explicitly in the fee curve so LP net is defended.
On RWA, the fee-inelastic weekend/gap arb tolerates the extra fee.

**Build differently NOW.** (i) Parameterize the fee curve to accept a **protocol-fee input** and
re-solve net-to-LP — don't hardcode as if protocol fee = 0. (ii) Re-run memo 03 with a nonzero
protocol fee before param freeze; if the calm-market hurdle (PT-3) already fails at protocol
fee = 0, it fails harder here → another reason to raise the MEME floor.

## Scenario 3 — Gas holiday ends (day ~90, ~2026-09-29)

**Threat.** Gas-subsidized bot/wash volume evaporates (memo 02): a plausible 20–60% of MEME
volume disappears, fees fall, and `emitted ≤ β·revenue` shrinks emissions in lockstep →
emission-rented TVL rationally exits right at the cliff.

**What survives.** The mechanism is *designed* for this — emissions are a dividend of activity,
so they *should* shrink with revenue (not a bug). Fee-**inelastic** flow (RWA weekend/gap arb,
WETH-majors arb, organic) survives and keeps paying. RWA revenue is gas-holiday-independent.

**Counter.** Weight emissions and TVL toward **fee-inelastic** pairs (RWA stock tokens, WETH
majors) before the cliff, not gas-holiday-inflated memecoins. **Pre-announce** the day-90
step-down so LPs price it in and don't panic-exit. Publish "organic-adjusted volume" (memo 02)
so the market isn't surprised.

**Build differently NOW.** (i) Do the flow census **before** the cliff so we know which pools are
subsidy-dependent. (ii) Structure the emission schedule / per-pool caps to lean toward inelastic
flow. (iii) Set expectations publicly on the day-90 transition (GTM 7).

## Scenario 4 — 90% chain-volume collapse

**Threat.** RH-Chain went from >$500M/24h peak to "tens of millions" baseline; a further 90%
collapse to low-single-digit-millions/day is on the table for a young chain. Fees and emissions
collapse; TVL flees; depth (hence routing, memo 03 PT-4) craters — a death spiral.

**What survives.** Two things: (a) the **RWA franchise** — 24/7 stock tokens with recurring,
structural weekend-drift arb are the most volume-resilient, chain-idiosyncratic flow (they exist
because Robinhood issues them, not because of a memecoin cycle); (b) **fixed costs are low** —
no upgradeable infra to maintain, immutable money paths, keepers are cheap. FERA can hibernate.

**Counter.** Anchor the franchise on RWA + WETH majors (resilient) rather than memecoin
volume (cyclical). Keep the protocol capital-light so it survives a long trough. The token's
`emitted ≤ β·revenue` bound means it **cannot over-issue into a collapse** — no hyperinflation
spiral, unlike subsidy tokens; the flywheel idles gracefully.

**Build differently NOW.** (i) Do **not** let the P&L or emission schedule assume peak volume —
size everything to the *baseline* tens-of-millions, treat spikes as upside. (ii) Make RWA a
first-class v1 pillar, not a follow-on, for volume resilience. (iii) Keep ops/keeper costs
minimal and fully fail-static so a trough is survivable, not fatal.

## Cross-cutting takeaways (what to build differently NOW)
1. **The moat is depth + token flywheel + calibration data + UX — never the hook.** Everything
   here points to seeding depth and the flywheel as **V1** (reinforces PT-4).
2. **Parameterize for a v4 protocol fee and for the gas-holiday cliff explicitly** — don't freeze
   params assuming protocol fee = 0 and peak volume.
3. **RWA is the resilience pillar.** It survives forks (data moat), a volume collapse (structural
   flow), and the gas cliff (gas-independent). Give it first-class v1 weight.
4. **The emission bound is a macro feature, not just an anti-wash rule** — it prevents
   over-issuance into a collapse. Protect it (memo 04 PT-2/PT-5): if boost or gaming breaks the
   bound, we lose this macro safety too.

**Data needed next:** RH-Chain volume/TVL time series (to size the baseline vs peak), Uniswap
governance stance on the v4 protocol fee for RH-Chain, and Arrakis's product roadmap on-chain.
