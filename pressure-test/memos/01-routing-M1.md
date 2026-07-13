# Memo 01 — M1 Routing Reachability (Gates V1 & V2)

**Verdict: CONDITIONAL** — not testable this session (no funds/keys). This is the exact
live runbook, metrics, latencies, PASS/FAIL thresholds, and fallback designs. **Do not
deploy mainnet until this test PASSES (MASTER_SPEC §11: V1–V2 before any mainnet deploy).**

## 0. Why this is the first gate

FERA's entire go-to-market is *wave-riding*: we deploy pools for pairs **already trading**
and win flow by winning depth, because routers deliver volume to the best net price
(SHARED_CONTEXT §4). If external routers do **not** see and quote a flagless hooked v4 pool,
we have no organic flow and the whole thesis collapses regardless of how good the fees are.
The hook is deliberately flagless (open swaps, no sender gate) precisely so it lands in the
"auto-allowlist lane" for Uniswap routing — **this memo exists to verify that assumption is
true on Robinhood Chain, not just plausible.**

The design routes by construction *if* three things hold, which we must each prove:
1. **Interface/routing-API indexes arbitrary hooked pools** (V2). Uniswap's routing API and
   UniswapX order server must include hooks they did not ship. Some deployments allowlist
   hooks; some quote any pool with the dynamic-fee flag. Unknown for RH Chain.
2. **Solvers/aggregators can *fill* against the hook within gas budget** (V1). Our
   `beforeSwap`+`afterSwap` ≤40k gas overhead must not break solver simulation or make us
   uncompetitive on gas-inclusive net price.
3. **We actually win net price** — a depth *and* fee edge, not just a marginally better
   headline price (see memo 03 PT-4: without depth, high-fee toxic flow is adversely selected).

## 1. Runbook (mainnet, small, reversible)

**Prereq (Deployment 5):** `docs/CHAIN.md` confirms canonical addresses (v4 PoolManager,
Universal Router, Permit2, UniswapX reactor + order server endpoint, 1inch RH-Chain router,
Alchemy RPC). Do not run until confirmed.

**Budget:** ≤ $5k total at risk. Two pools. ~1 week wall-clock. Kill switch = withdraw
liquidity (never gated for the Vault owner).

### Step A — Deploy the minimal flagless hooked pool
1. Deploy `FeraHook` (audit-frozen or a behaviorally-identical test hook with the same gas
   profile and the same flag bitmap) + a minimal Vault to hold the position.
2. Initialize **two** pools with the dynamic-fee flag:
   - **P1 (V1/V2 core):** a live memecoin/WETH pair with existing vanilla v3/v4 depth. MEME regime.
   - **P2 (V2 RWA-review probe):** a flagship Stock Token (e.g. NVDA) vs USDG/WETH. RWA regime.
     This is the pool most likely to trip a Uniswap "majors review" — we want to learn that early.
3. Seed **modest** liquidity via the Vault at a price **marginally better** than the best
   competing pool: target a mid that is **5–15 bps** better on the quoted side, with enough
   depth that a $1–5k test swap gets a strictly better net quote than the incumbent pool.
   Record exact tick, liquidity, and the competing pool's depth at t0.

### Step B — Measure routing inclusion (V2)
For each of P1, P2, over ≥72h spanning a weekend (RWA needs the weekend + a Monday open):
1. **Uniswap interface / routing API:** query the RH-Chain routing API (or the interface
   quote endpoint) for a swap on the pair, size-swept ($100 / $1k / $5k). Record whether our
   pool appears in the route and its share of the split route. Poll every 5 min.
2. **UniswapX:** submit signed test orders (RFQ/Dutch) for the pair; observe whether solvers
   fill through our pool (decode the fill route from the settlement tx).
3. **1inch:** hit the 1inch RH-Chain quote+swap API for the pair; record pool inclusion.
4. **Control:** simultaneously query a *vanilla* pool we deploy at the same better price but
   **without** the hook, to separate "routers ignore hooks" from "routers ignore new pools."

### Step C — Measure fill economics (V1)
For every observed fill through our pool: record gas used, `lpFeePips` applied, realized net
price vs the incumbent, and end-to-end latency from quote to inclusion.

## 2. Metrics & PASS/FAIL thresholds

| Metric | Definition | PASS | FAIL |
|--------|------------|------|------|
| **Interface inclusion (V2)** | % of interface/routing-API quotes that include our pool when our net price is best | ≥ 80% within 24h of deploy | < 50% after 72h |
| **UniswapX fill rate (V1)** | % of test orders solvers route (partly) through our pool when we're best price | ≥ 50% | ~0% after 72h with better price |
| **1inch inclusion (V1)** | pool appears in 1inch route when best price | ≥ 50% of size-swept quotes | ~0% |
| **Indexing latency (V2)** | time from pool init → first appearance in a router quote | ≤ 6h | > 48h |
| **Gas competitiveness (V1)** | our hook per-swap overhead | ≤ 40k gas (§5) and net price still best after gas | overhead breaks solver sim or flips net price |
| **RWA review trigger (V2)** | does P2 (Stock Token) get quoted, or blocked/greylisted pending review? | quoted, OR a known, bounded review path | silently never quoted |
| **Control delta** | inclusion(hooked) vs inclusion(vanilla-new-pool) | within ~10pp (hooks not penalized) | hooked ≪ vanilla → hook-specific block |

**V1 verdict = PASS iff** UniswapX fill-rate PASS **and** 1inch inclusion PASS **and** gas PASS.
**V2 verdict = PASS iff** interface inclusion PASS **and** latency PASS **and** RWA-review has a
known path. Any FAIL → the corresponding fallback (below) is mandatory before mainnet.

### Latency notes
- ~100ms blocks mean on-chain confirmation is fast; the binding latency is **off-chain router
  indexing** (subgraph/pool-discovery refresh), typically minutes–hours. Measure it; if the
  routing API only refreshes its pool set on a schedule or via an allowlist PR, that is the
  real gate, not chain speed.

## 3. FAIL criteria (halt conditions)
- Our pool, priced strictly better, is **never** included by the Uniswap interface after 72h
  and the vanilla control **is** → hook-specific allowlist block → **V2 FAIL**, execute Fallback B.
- UniswapX solvers never fill despite best price → **V1 FAIL**, execute Fallback C.
- P2 Stock Token pool is silently dropped → **V2 RWA FAIL**, execute Fallback A + reconsider
  RWA at mainnet (ship MEME-only v1).
- Gas overhead makes us net-price-uncompetitive even when depth is better → escalate to
  Contracts (1) to shrink the hook; re-run.

## 4. Fallback designs (build these in parallel; do not discover the need at mainnet)

**Fallback A — Allowlist conversation (Uniswap Labs / interface).**
Prepare the ask now: pool addresses, hook bytecode + audit, the "flagless, open-swap,
no-protocol-fee-on-swaps" argument (we are additive routed depth, not an extraction hook).
Target: inclusion in the RH-Chain routing pool set / token+hook allowlist. Owner: GTM (7) +
Orchestrator. Lead time can be weeks — start at deploy, not at FAIL.

**Fallback B — Direct interface/aggregator integration.**
If the public interface won't auto-index, integrate as a liquidity source directly with the
aggregators that dominate RH-Chain flow (1inch, Native, Rialto's built-in aggregation). Ship a
quoting adapter (our Backend serves a standard quote endpoint; register as a PMM/AMM source).

**Fallback C — Become the solver.**
If UniswapX solvers won't route to us, run our **own** UniswapX filler that sources from our
pools and competes in the Dutch auction. This captures our own routed flow and is a v2 asset
anyway (MEV internalization roadmap). Also stand up an RFQ endpoint for 1inch/Native so we are
a first-class PMM source. This is the strongest fallback: it makes us independent of third-party
indexing goodwill.

**Fallback D — Depth-first seeding (always on).**
Regardless of routing outcome, per memo 03/PT-4 the regime pool must win **depth**, not just
headline fee, or toxic flow is adversely selected away from it. Emissions-bootstrapped TVL is
therefore a V1 dependency, not a growth nicety. Quantify minimum depth multiple per target pair
before mainnet.

## 5. What real data I need next
1. `docs/CHAIN.md` confirmed router/reactor/aggregator endpoints + whether the RH-Chain Uniswap
   routing API uses a hook allowlist or quotes any dynamic-fee pool (this single fact largely
   decides V2).
2. A funded deployer key + ≤$5k for the two probe pools.
3. Incumbent pool depth/fee snapshots for the two target pairs (to set the "marginally better"
   seed price precisely).
