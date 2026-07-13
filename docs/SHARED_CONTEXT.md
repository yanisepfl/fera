# FERA — SHARED CONTEXT (verbatim from Mission Pack v2)

Every agent reads this plus [`MASTER_SPEC.md`](MASTER_SPEC.md). Where this and MASTER_SPEC
disagree on a *shared interface*, MASTER_SPEC is the reconciled contract and wins; where
they disagree on *design intent*, this document (the locked design) wins — flag the conflict
to the Orchestrator.

> **⚠ PRINCIPAL AMENDMENTS (post-date this verbatim text — see MASTER_SPEC §13):**
> - **Emission split:** LP-dominant, under Mechanism optimization (Decision-A′; working prior
>   80/10/10) — NOT the 45/45/10 in §6 below.
> - **Staking boost applies to LP emissions ONLY** (Decision B), NOT "trader/LP" as in §8 below.
> - **Cold-start:** early usage emissions intentionally fund little TVL; the genesis war-chest
>   seeds initial liquidity (DM-2).
> - **OPEN LIQUIDITY ADOPTED (D-11):** the §1 "gated LIQUIDITY" clause below is REPEALED —
>   LPing is permissionless; before-liquidity hooks now enforce only a uniform anti-JIT
>   min-hold (D-13); emissions are the vault's exclusive carrot (INV-14).
> - **VAULT ARCHITECTURE v2 (D-12):** §3's "MEME = FULL-RANGE, NEVER REBALANCED" single-position
>   model is REPLACED by shaped band ladders + ≤2 risk tranches + drip recentering
>   (principal never swapped; only fee income redeployed) — see `docs/VAULT_ARCHITECTURE.md`.
> The paragraphs below are the ORIGINAL locked design; treat the amendments above as overriding.

---

We are building FERA on Robinhood Chain (permissionless Arbitrum Orbit L2, mainnet July 1
2026, ~100ms blocks, EVM, Foundry/Hardhat, Alchemy RPC, Chainlink is the chain's official
oracle infra with Data Feeds/Data Streams/CCIP live, 90-day gas-fee holiday running).

Chain facts that shape the design:
- Uniswap deployed v2, v3, v4, and UniswapX day one as the chain's primary public AMM;
  first-week Uniswap volume $250M+; chain peaked >$500M/24h, mostly WETH pairs + memecoins;
  post-spike baseline is tens of millions daily. Volume is ROUTED (Uniswap interface,
  UniswapX solvers, 1inch, bots) — flow follows best price, not brands.
- ~95 Robinhood-issued Stock Tokens (NVDA, AAPL, GOOG...) trade 24/7 with Chainlink feeds +
  proof-of-reserve; they drift from cash price over weekends and reconcile at Monday open
  (recurring structural arb flow).
- Competitors on-chain: Uniswap (public AMM), Arcus (dYdX+Robinhood stock DEX), Rialto
  (propAMM spot, has built-in quote aggregation), Lighter (ZK perps), Pleiades (prop AMM),
  1inch, Native (execution), Morpho (~$90M TVL via Robinhood Earn at ~7%), Arrakis (ALM for
  token issuers), Meridian (RWA perps/prediction markets). NOBODY offers: regime-aware fee
  pricing, retail-usable managed LP vaults on public pairs, or (later) a native launchpad.
- Closest analog is Arrakis (issuer-facing treasury ALM). We differentiate: LP-depositor-
  facing, hook-native dynamic fees, bot-flow monetization, token flywheel.

Core design (LOCKED — challenge only via written escalation to Orchestrator):
1. HOOK: one flagless Uniswap v4 hook on the canonical PoolManager. Open swaps — any router,
   aggregator, or bot can swap permissionlessly (no delta flags, no sender gate on swaps →
   auto-allowlist lane for Uniswap routing). Gated LIQUIDITY: beforeAddLiquidity/
   beforeRemoveLiquidity revert unless caller is the Fera Vault. Per-pool immutable regime
   set at initialization.
2. REGIMES (dynamic LP fee set in beforeSwap via fee override; afterSwap emits accounting
   events):
   - MEME: EWMA realized-volatility estimator from tick movement → fee in [~0.3%, ~3–5%];
     asymmetric sell-side fee under one-sided net flow; (launch-decay curve reserved for the
     launchpad module). The more violent/mechanical the flow, the more LPs earn — wash/volume
     bots are fee fountains by design.
   - RWA: low fee (~1–5 bps) during underlying market hours (on-chain schedule + keeper
     holiday flags); widened fee (~30–100 bps) when market closed; continuous overlay scaling
     with |pool price − Chainlink feed|, clamped, never reverting swaps. Weekend-drift
     arbitrage becomes recurring LP income instead of LP loss.
   - EVENT regime: reserved for v2 (time-to-resolution-aware fees for outcome tokens); design
     for it, don't build it.
   - MEV internalization (Angstrom-style top-of-block auction paying LPs): explicitly v2
     roadmap, NOT v1 — do not compromise open routing for it.
3. VAULT: sole owner of all v4 positions. Users deposit single or dual assets per pool →
   fungible ERC-20 vault shares per pool (one position/few bands per pool total; position
   count scales with pools, not users). Strategies are rule-based, transparent, keeper-
   executed within hardcoded bounds, zero discretion:
   - MEME pools: FULL-RANGE, NEVER REBALANCED. No exceptions. IL is compensated by the
     volatility-scaled fee, not fought with positioning.
   - RWA pools: tight band centered on the Chainlink price; recenter only when the ORACLE
     moves past a hysteresis threshold, only during market hours, TWAP-sanity-checked;
     widen/partially withdraw off-hours.
4. GO-TO-MARKET LOGIC (wave-riding thesis — all agents internalize it): we deploy pools for
   pairs ALREADY trading (top WETH/memecoin pairs, flagship Stock Tokens vs USDG/WETH).
   Routers deliver volume automatically to whichever pool quotes the best net price; we win
   flow by winning depth; we win depth because our LPs earn more per dollar (regime fees
   monetize toxic/bot/weekend flow that bleeds vanilla LPs). Emissions solve the only cold
   start we have — TVL — because liquidity, unlike users, is rentable with a token (see the
   $90M chasing 7% in Morpho). The launchpad is a MONTH-3 GROWTH MODULE bolted onto working
   infrastructure (free launches, bonding curve, graduation into vault-owned locked
   full-range shares whose yield auto-compounds into the position forever), not the v1
   product.
5. REVENUE: a 10% performance fee on LP fee yield, taken at the Vault at fee-collection time
   — never on principal, never on swaps, never on deposits/withdrawals/launches. Traders
   (and bots) pay zero protocol fees on any venue; LPs pay only when they earn.
   RevenueDistributor split, immutable: 50% sFERA stakers / 25% treasury (timelocked) / 25%
   ops. Secondary stream: 1/3 of esFERA instant-exit forfeitures.
6. TOKEN (FERA): fixed 1B supply. Genesis: 10% treasury (team/liquidity/war chest, vested +
   timelocked). 90% emitted via usage only. Weekly epoch emission = min( S-curve cap(t)
   [logistic, ~4-year horizon], β × epoch protocol revenue valued at manipulation-capped FERA
   TWAP, β ≈ 0.8 ). Split per epoch: 45% to traders pro-rata to dynamic LP fees PAID (a
   rebate; combined with the fee this makes wash-farming net-negative by arithmetic), 45% to
   LPs pro-rata to fees EARNED on their vault shares, 10% treasury. Emissions can never exceed
   the value the protocol earned — a dividend of activity, not a subsidy.
7. ESCROW (esFERA): all trader/LP emissions arrive as non-transferable esFERA; linear ~6-
   month vest to FERA 1:1; instant exit at ~50% haircut; forfeitures split 1/3 burn / 1/3 to
   vesting stakers / 1/3 to RevenueDistributor.
8. STAKING (sFERA): no voting, no gauges, no bribes (emissions follow measured fees, not
   votes — this is ve(3,3) with voting replaced by measurement). Stakers get: up to ~2x boost
   on their own trader/LP emissions; 50% of protocol revenue (real-asset yield); optional
   time-lock with linearly decaying multiplier points. Optional per-pool FERA-pair emissions
   multiplier when the launchpad module ships.
9. Distribution accounting: hook afterSwap events + Vault fee-collection events → indexer →
   weekly Merkle roots on-chain → Distributor claims (in esFERA). Deterministic, reproducible,
   versioned; never hotfix a posted epoch.

Design language (frontend): family of alphix.fi and the Canary/Alma/Alps projects
(github.com/yanisepfl, github.com/carluzh) — minimal, dark-first, typography-led, one display
face + one mono for numbers, restrained accent, calm and data-dense; the same interface must
feel right for degens and for someone LPing NVDA.

Engineering rules: Solidity ^0.8.26, Foundry, 100% branch coverage on money paths, NatSpec,
no upgradeable proxies on money paths, params behind 48h timelock or immutable, pause allowed
on Vault deposits only (never on swaps or withdrawals), every external call scrutinized under
v4 flash accounting, written as if a Sherlock auditor reads it tomorrow.

Open verification items (Pressure-Test agent owns; results gate mainnet):
V1. Do UniswapX solvers + 1inch on Robinhood Chain route to arbitrary flagless hooked v4
    pools when price is better? (Live small-pool test.)
V2. Does the Uniswap interface auto-route our pools (flagless hook = auto-allowlist), incl.
    whether RWA majors pairs trigger their review?
V3. What share of current memecoin volume is bot/farm vs organic (informs fee-curve
    calibration, not viability — we monetize both)?
V4. LP yield superiority: backtest regime fees vs vanilla v3/v4 LP on identical pairs using
    real chain data (incl. a weekend for Stock Tokens).
