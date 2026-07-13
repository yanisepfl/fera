# FERA Vault v2 — Competitive Scan (ALM / shaped liquidity / tranches / JIT defense)

**Author:** Agent V (vault architecture review). **Date:** 2026-07-11.
**Method:** live web research 2026-07-11 (agent training cutoff Jan 2026; post-cutoff items
sourced from July-2026 press). Confidence tags: **HIGH** = official post-mortem/docs or
multiple independent sources; **MED** = single good source; **LOW** = inference/recall.
**Reviews:** `docs/VAULT_ARCHITECTURE.md` (D-12). Companion: `ARCHITECTURE_REVIEW.md`,
`SIM_RESULTS.md`, `OPEN_DECISIONS.md` in this directory.

---

## 1. Protocol-by-protocol

### 1.1 Arrakis (v2 / Pro / HOT AMM) — the named closest analog, and it is on our chain

- **Arrakis v2 / Pro** (HIGH): non-custodial ALM; v2 is a modular vault system managing
  1–N concentrated positions per vault with off-chain strategy executors ("Palm"/Pro =
  managed offering). Arrakis Pro today targets **token issuers' Protocol-Owned Liquidity**
  — issuer retains treasury custody, Arrakis executes MM strategies within issuer-set
  parameters — and supports Uniswap v4, Aerodrome, PancakeSwap Infinity via modules.
  Sources: [docs.arrakis.finance — Arrakis Pro](https://docs.arrakis.finance/text/introduction/arrakisPro.html),
  [Uniswap v4 module](https://docs.arrakis.finance/text/modules/uniV4Module.html),
  [Arrakis x Uniswap v4](https://arrakis.finance/blog/arrakis-x-uniswap-v4-is-here).
- **HOT AMM** (HIGH): "Hybrid Order Type" AMM built with Valantis. Two lanes: normal AMM
  swaps with a **dynamic fee that rises until a solver posts a price update**, and RFQ
  "flash swaps" filled against **signed quotes from the off-chain Arrakis Quoting Service**
  at deterministic prices. Purpose: LVR reduction/mitigation for LPs. This is off-chain-
  quoter-dependent market making — a different trust model from FERA's rule-based on-chain
  bounds. Sources: [HOT live](https://arrakis.finance/blog/hot-the-mev-aware-amm-built-to-empower-lps-is-live),
  [HOT whitepaper](https://docs.arrakis.finance/text/modules/hotAmm/whitepaper.html),
  [Valantis HOT](https://mirror.xyz/valantisxyz.eth/npjC6mMjAPBUEueNZ7dnqFpXskeZifDydPOzLOM3Wvg).
- **On Robinhood Chain** (HIGH, corroborates SHARED_CONTEXT): listed in day-one ecosystem
  coverage as the chain's on-chain market-making protocol **for token issuers** — i.e.
  issuer-facing, not LP-depositor-facing. Source:
  [KuCoin — Robinhood Chain ecosystem overview](https://www.kucoin.com/news/flash/robinhood-chain-ecosystem-overview-key-projects-to-watch).
- **Relevance to FERA:** validates pooled-share multi-position vaults on v4; does **not**
  offer public-pair retail LP deposit products on this chain, no risk tranches, no
  regime/dynamic fees at the pool level (HOT's dynamic fee is solver-decay, not
  volatility-regime), no emissions flywheel. Their wedge is issuers; ours is LP depositors.

### 1.2 Gamma Strategies — the deposit-pricing cautionary case (Jan 2024)

- **Architecture** (HIGH): "Hypervisor" vaults, pooled ERC-20 shares over typically **two
  positions (base + limit)** per pool, active keeper rebalancing; on v4 they advertise
  **MultiPosition strategies with up to 20 positions** with arbitrary liquidity shapes
  (MED — docs via search). Source: [docs.gamma.xyz strategies](https://docs.gamma.xyz/gamma/lp-vaults/strategies).
- **Jan-4-2024 exploit — the exact vector** (HIGH): Gamma's deposit path had four guards,
  one of which was a **price-change threshold vs TWAP** that gates deposits. On several
  LST/stable vaults the threshold was **misconfigured by automation scripts to allow
  −50%/+100% price change instead of the intended ~2%**. Attacker flash-loaned, pushed the
  pool price inside that huge tolerance, then deposited at the manipulated spot ratio and
  **minted a disproportionate number of LP shares** (share mint priced off manipulated
  reserves), then exited after price reversion. Loss reported $3.4M–$6.2M across sources
  (≥$4.5M per rekt). Deposits were halted; vault code itself unchanged — **it was a guard
  parameterization failure, not a math bug**.
  Sources: [Gamma post-mortem](https://medium.com/gamma-strategies/post-mortem-remediation-plan-9a62f10d90f3),
  [rekt.news](https://rekt.news/gamma-strategies-rekt),
  [Verichains analysis](https://blog.verichains.io/p/gamma-protocol-exploit-analysis),
  [The Block](https://www.theblock.co/post/270338/defi-protocol-gamma-strategies-suffers-an-estimated-3-4-million-exploit).
- **The guard that kills the vector:** (1) deposit share-mint priced at **TWAP-valued NAV**
  with a **tight, hard-bounded** spot-vs-TWAP deviation gate (revert deposit outside it —
  deposits MAY pause, INV-11 allows); (2) **ratio-matched dual-token deposits** so the
  depositor cannot choose an advantageous single-sided ratio at a manipulated price;
  (3) **threshold bounds hardcoded in the contract** (timelocked within an immutable
  range), never sourced from off-chain config automation — Gamma's actual failure was the
  config pipeline. (4) deposit caps per tx/epoch as blast-radius control.
- **Fate:** operating; revenue-funded restitution plan (~1.7 years at then-current revenue,
  MED). Lesson: deposit-pricing guards are **parameter-fragile** — encode bounds on-chain.

### 1.3 Charm Alpha Vaults — the base+limit two-position pattern

- (HIGH) First passive-rebalancing v3 ALM (May 2021): pooled ERC-20 vault holding exactly
  **two positions**: a symmetric **base order** around price X and a single-sided
  **limit order** just above/below price placed with the leftover token; keeper calls
  `rebalance()` every ~48h; **never swaps** — rebalancing toward 50/50 happens by letting
  the market lift the limit order (earning fees rather than paying them + no MEV surface).
  Sources: [Charm whitepaper](https://learn.charm.fi/charm/products-overview/alpha-vaults/whitepaper),
  [strategy docs](https://learn.charm.fi/charm-finance/alpha-vaults/strategy),
  [contracts](https://github.com/charmfinance/alpha-vaults-contracts).
- **Relevance:** the **no-swap rebalancing idea** is directly stealable for FERA's drip:
  deploy single-sided fee income as a Charm-style limit band on the excess-token side
  instead of swap-assisting to 50/50 — zero swap cost, zero sandwich surface, and it
  self-rebalances. See ARCHITECTURE_REVIEW (b)/(g).

### 1.4 Steer Protocol

- (MED) Multi-position "Smart Pools" infrastructure across many DEXs/chains; strategies as
  off-chain apps (their marketing: rivals limit to 2–3 positions, Steer runs many);
  keeper-network execution. No tranches, no fee regimes, standard pooled shares.
  Sources: [docs.steer.finance](https://docs.steer.finance/flagship-apps/smart-pools/Strategies/fluid-liquidity/),
  [steer.finance](https://steer.finance/liquidity-management/).
- **Relevance:** existence proof that **many-band ladders are operationally fine** on
  v3-style AMMs; their differentiation is strategy variety, not accounting structure.

### 1.5 Ichi

- (MED) Single-sided deposit vaults ("deposit one token"); algorithmic range management
  advertised as no-swap on deposit/rebalance, directional inventory-aware ranges.
  Sources: [docs.ichi.org](https://docs.ichi.org/home/how-ichi-works),
  [Ichi vaults intro](https://medium.com/@ichidao/introduction-to-ichi-vaults-improving-liquidity-management-in-defi-48f0a5fa8309).
- **Relevance:** single-sided UX = table stakes (FERA's swap-assist deposit covers it; the
  no-swap deposit variant — mint into the band single-token-side like a limit order — is
  the cheaper/safer implementation to consider).

### 1.6 Mellow

- (MED) Evolved from v3 ALM vaults into modular vault infrastructure; current flagship:
  **MultiVault** aggregating isolated subvaults with composite LP tokens (LRT/restaking
  focus, curator model). Not an AMM-LP tranching system.
  Source: [docs.mellow.finance](https://docs.mellow.finance/mellow-vaults-overview).

### 1.7 Veda (BoringVault)

- (HIGH for architecture) The dominant 2025 "vaultization" stack: **BoringVault** (~100-line
  custody core) + **Teller** (deposit/withdraw; **mints at an Accountant-published exchange
  rate; enforces share lock periods to protect against MEV**) + **Accountant** (off-chain
  computed exchange rate, **on-chain rate-limited and band-limited** updates) + **Manager**
  (Merkle-whitelisted strategy calls). Sources: [docs.veda.tech architecture](https://docs.veda.tech/architecture-and-flow-of-funds),
  [BoringVault](https://docs.veda.tech/architecture-and-flow-of-funds/boringvault).
- **Relevance:** two direct precedents for FERA guards — (1) **share lock period after
  mint** = our `DEPOSIT_COOLDOWN_SEC` (kills flash-round-trip share games even if pricing
  is briefly wrong); (2) **bounded rate movement** for NAV inputs = our hard-bounded
  TWAP-deviation gate. Their NAV is oracle/off-chain (curator trust); ours must stay
  on-chain-verifiable — keep Veda's *bounds* pattern, not its trust model.

### 1.8 Bunni v2 — the R-17 cautionary case, VERIFIED

- **Design** (HIGH): v4 hook suite; **Liquidity Distribution Functions (LDFs)** — per-pool
  programmable continuous liquidity shapes re-evaluated as price moves; **surge fees**
  (instant fee spike on rebalance/volatility events to price toxic flow); **am-AMM**
  (auction-managed AMM per Adams et al. — sell the right to manage the pool/capture arb);
  autonomous rebalancing. The closest prior art to "shaped pooled liquidity with smart
  fees" that has actually shipped.
- **Exploit, Sept 2 2025** (HIGH): total **~$8.3–8.4M** ($2.4M Ethereum + ~$5.9–6M
  Unichain). Root cause: **rounding-direction bug in the idle-balance update inside
  `BunniHubLogic::withdraw()`** — `balance - balance.mulDiv(shares, totalSupply)` rounded
  **down** on the subtracted amount under the assumption "underestimating liquidity is
  safe". Attack: flash-loan swap to set up state → **44 tiny withdrawals**, each ratcheting
  the pool's tracked active balance down disproportionately vs shares burned (USDC active
  balance pushed 28 wei → 4 wei, −85.7%) → pool now misprices liquidity → sandwich swaps
  extract value. **The bug was NOT in the LDF curve math itself — it was in the share/
  idle-balance accounting *around* the shape.** Post-mortem fix: flip rounding up.
  Sources: [Bunni official post-mortem](http://blog.bunni.xyz/posts/exploit-post-mortem/),
  [Verichains](https://blog.verichains.io/p/bunnixyz-vulnerability-exposed-how),
  [QuillAudits](https://www.quillaudits.com/blog/hack-analysis/bunni-v2-exploit),
  [The Block](https://www.theblock.co/post/369564/bunni-smart-contract-rounding-error),
  [Halborn](https://www.halborn.com/blog/post/explained-the-bunni-hack-september-2025).
- **Wind-down** (HIGH): announced Oct 2025 — growth halted, relaunch would cost "6–7
  figures in audits and monitoring" they didn't have; contracts relicensed BUSL→MIT.
  Sources: [Decrypt](https://decrypt.co/345621/decentralized-exchange-bunni-pulls-the-plug-following-8-4m-flash-loan-exploit),
  [BeInCrypto](https://beincrypto.com/bunni-shutdown-defi-hack/).
- **Concrete lessons for FERA's discrete-band implementation:**
  1. Discrete standard v4 positions do kill the custom-curve surface — but **the killer
     class of bug (pro-rata `mulDiv` rounding on withdraw across custom state) lives in
     FERA's per-tranche share/NAV accounting too**. R-17 mitigation must target the
     accounting, not just "no LDF".
  2. **Rounding policy invariant:** every share↔asset conversion rounds against the user
     (mint: round shares down; withdraw: round assets down; internal balance decrements:
     round the decrement up). Make it a fuzzed invariant.
  3. **Security PoC must replay Bunni's exact pattern**: N tiny withdrawals + micro
     deposits, assert per-tranche NAV drift ≤ dust (ties to INV-15's "rounding dust" — the
     dust bound must be cumulative, not per-op).
  4. Surge fees: Bunni validated *instant* fee response to rebalance/vol events; FERA's
     EWMA lags one-shot jumps — first dump trades near floor fee (see review (g)).
  5. Post-incident economics: an $8.4M bug killed a protocol with real traction —
     wind-down driven by re-audit cost. Keep the money-path surface small (the ≤5-band
     choice is right) and budget for continuous monitoring.

### 1.9 Maverick v2 — what auto-shifting modes validate

- (HIGH) AMM with native, gas-free **bin shifting**: LP chooses **Mode Static / Right /
  Left / Both**; the contract moves the LP's bins to follow price (one-directional modes
  don't move back on reversals; Mode Both follows both ways). Directional LPs avoid IL
  while their bet is right; **Mode Both in choppy markets realizes whipsaw losses** —
  moving principal is a bet, always. Also "Boosted Positions" = incentives targeted at
  specific bin distributions. Source: [docs.mav.xyz — Understanding modes](https://docs.mav.xyz/guides/liquidity-providers/understanding-modes).
- **What it validates for FERA:** (1) *liquidity-follows-price is real demand* — Maverick
  built an entire AMM around it; (2) **mode-choice-as-product** validates tranche-choice-
  as-product (pick your risk shape, keep fungible accounting); (3) their principal-moving
  modes churn IL in chop — exactly what our sim reproduces (LadderRecenter loses PnL in
  Scenario A) — supporting FERA's principal-passive default with income-driven following.

### 1.10 Uniswap-v4-native landscape 2025–2026 (what emerged after v4 launch)

- **ALM incumbents ported:** Arrakis, Gamma, Bunni (†) launched v4 vault/hook products
  (MED). Source: [DWF Labs — Uniswap v4 in 2025](https://www.dwf-labs.com/research/457-what-s-new-in-uniswap-v4-three-key-changes-and-two-new-protocols).
- **Angstrom (Sorella Labs)** (HIGH): v4 hook DEX; per-block **batch auction at one uniform
  clearing price** (sandwich structurally impossible); searchers **bid for zero-fee arb
  rights, proceeds paid to LPs**. This is toxic-flow *internalization by auction* — the
  v2-roadmap MEV lane FERA explicitly deferred (SHARED_CONTEXT §2). JIT defense falls out
  of uniform pricing rather than holds/penalties.
  Sources: [Uniswap Foundation builder update](https://www.uniswapfoundation.org/blog/builder-update-31-angstrom-oz-hook-library-eth-nyc),
  [Cantina competition](https://cantina.xyz/portfolio/2c7d45e3-0358-4254-8698-b4500fe7c6a9).
- **OpenZeppelin `uniswap-hooks` library** (HIGH — source read): audited hook set including
  **`LiquidityPenaltyHook`** — the canonical JIT defense precedent:
  - flags: `afterAddLiquidity` + `afterRemoveLiquidity` **+ both RETURN_DELTA flags**;
  - on add within `blockNumberOffset` of last add: **withholds the position's accrued
    fees**; on remove within the window: penalty = `fees × (1 − blocksSinceAdd/offset)`
    (100% at same block, linear decay), **donated via `poolManager.donate()` to in-range
    LPs at removal time**;
  - keys state by `Position.calculatePositionKey(sender, tickLower, tickUpper, salt)`;
  - measures the window in **blocks** (must be time-derived on a 100ms chain);
  - caveat: remove **reverts with `NoLiquidityToReceiveDonation`** if no in-range
    liquidity exists to receive the donation.
  Source: [LiquidityPenaltyHook.sol](https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/general/LiquidityPenaltyHook.sol),
  [OZ audit note](https://www.openzeppelin.com/news/openzeppelin-uniswap-hooks-v1.1.0-rc-1-audit).
  **Key property vs FERA's D-13 hard min-hold: it never blocks exit — it confiscates the
  JIT profit instead.** See review (d).
- **Flaunch** (MED): memecoin launchpad hook on Base (creator fees, buyback bid wall,
  launch no-sell window) — highest-volume 2025 hook class; relevant only to FERA's month-3
  launchpad module.
- **EulerSwap** (MED): v4 swaps backed by lending-vault collateral (capital triple-use);
  different lane.
- **Cork Protocol** (HIGH): $11M exploit May 28 2025 — **access-control vulnerability in
  its v4 hook** (anyone could invoke privileged hook flows). Lesson for `FeraHook`: hook
  entry points must verify `msg.sender == poolManager` and pool-key binding; hook-adjacent
  admin surfaces are the v4 attack pattern with the most losses so far.
  Source: [Dedaub — Cork hack](https://dedaub.com/blog/the-11m-cork-protocol-hack-a-critical-lesson-in-uniswap-v4-hook-security/).
- **JIT-defense summary of precedents:** same-block add/remove bans and short block delays
  (v3-era thinking, useless at 100ms blocks); OZ fee-forfeiture penalty (best fit);
  Angstrom-style auctions (v2 roadmap); Bunni surge fees (raise the cost of the moment JIT
  targets). No shipped protocol uses a long *hard* min-hold that reverts removes — FERA
  would be the first, and the sim shows why nobody does (it must be ≥~30 min to bite,
  which collides with withdrawal liveness). (HIGH for OZ/Angstrom mechanics; MED for the
  "no shipped hard min-hold" negative claim.)

### 1.11 Risk tranches on LP/yield — precedent check

- **BarnBridge SMART Yield** (HIGH): senior (fixed) / junior (variable) tranches over
  lending yield. **SEC settlement Dec 22 2023** — tranches deemed an unregistered
  security offering; DAO ordered to **cease SMART Yield operations**, ~$1.7M total
  penalties; product dead. Sources: [SEC press release](https://www.sec.gov/newsroom/press-releases/2023-258),
  [CoinDesk](https://www.coindesk.com/policy/2023/12/22/sec-blasts-purportedly-decentralized-daos-in-17m-settlement-with-barnbridge).
- **Idle Finance Perpetual Yield Tranches** (MED): senior/junior over lending-protocol
  yield, still documented live (Ethereum, Polygon zkEVM, Optimism).
  Source: [docs.idle.finance](https://docs.idle.finance/products/yield-tranches/overview).
- **On AMM LP fee yield specifically: no live major precedent found.** Closest structures:
  Charm/Gamma base+limit (two positions, one share class), Maverick modes (user-selected
  shape, per-user positions). FERA's Core/Anchor (two share classes over **disjoint band
  sets**, no payment waterfall, no fixed-yield promise, no senior claim on junior assets)
  is materially different from BarnBridge's waterfall tranches — but the *word* "tranche"
  and the "lower-risk class" marketing are what the SEC order attacked. Route naming/
  framing to legal (R-8 owner). (Assessment: MED/analysis.)

---

## 2. Comparison table

| Protocol | Position architecture | Share accounting | Tranches? | JIT defense | Deposit-pricing guard | Fate / headline lesson |
|---|---|---|---|---|---|---|
| **Arrakis v2/Pro/HOT** | 1–N managed positions; modules per venue; HOT = RFQ + solver-decay dynamic fee | pooled ERC-20 per vault | No | n/a (HOT internalizes via quotes) | manager-priced (issuer trust) | Alive, pivoted issuer-facing; on Robinhood Chain. Closest neighbor, different customer |
| **Gamma** | base+limit per pool; v4 multi-position (≤20) | pooled ERC-20 (Hypervisor) | No | none at pool layer | ratio check + **TWAP price-change threshold — misconfigured, $3.4–6.2M loss Jan 2024** | Alive, repaying. Lesson: guard *parameters* must be hard-bounded on-chain |
| **Charm Alpha** | exactly 2: base + single-sided limit; no-swap passive rebalance ~48h | pooled ERC-20 | No | none | TWAP deviation check on rebalance | Alive, small. Lesson: no-swap rebalancing (limit orders) is free and MEV-immune |
| **Steer** | many-band multi-position smart pools | pooled ERC-20 | No | none | strategy-level | Alive, infra play. Ladders are operationally proven |
| **Ichi** | single-sided vaults, directional ranges | pooled ERC-20 | No | none | vault ratio logic | Alive. Single-sided UX is table stakes |
| **Mellow** | subvault aggregation (MultiVault), curator model | composite LP tokens | No (isolated subvaults ≠ tranches) | none | curator/oracle | Pivoted to restaking infra |
| **Veda BoringVault** | strategy-agnostic custody + Merkle-gated manager | ERC-20 at Accountant rate | No | **share lock period post-mint** | **rate-limited, band-limited exchange-rate updates** | Alive, category leader. Bounds + share-lock patterns to steal |
| **Bunni v2** | **continuous LDF shapes** + surge fees + am-AMM on v4 | pooled shares + internal idle balances | No | surge fees (economic), am-AMM | n/a | **Dead** — $8.4M Sept 2025, withdraw-rounding ratchet (not the curve); wound down Oct 2025 |
| **Maverick v2** | per-user bins, native auto-shift modes | per-user (not pooled) | Mode choice ≈ risk menu, not share classes | none | n/a | Alive. Liquidity-follows-price + choice-as-product validated; principal-moving churns IL in chop |
| **Angstrom** | n/a (batch-auction DEX hook) | n/a | No | **uniform clearing price + arb-rights auction to LPs** | n/a | Live 2025, Paradigm-backed. The v2-roadmap way to kill JIT/MEV |
| **OZ LiquidityPenaltyHook** | (library, not protocol) | n/a | n/a | **withhold + forfeit fees on early remove, donate to in-range LPs; linear decay window** | n/a | Audited reference. The JIT guard FERA should adopt over a hard min-hold |
| **BarnBridge / Idle** | tranches over lending yield (not AMM LP) | senior/junior tokens | **Yes — waterfall** | n/a | n/a | BarnBridge killed by SEC (Dec 2023); Idle alive. Tranche *framing* is a regulatory surface |
| **FERA v2 (proposal)** | ≤5-band ladder/pool, drip recentering | ERC-20 per pool **per tranche** | **Yes — disjoint band sets** | uniform min-hold (D-13) — **contested, see review (d)** | TWAP/oracle NAV + cooldown (to be hard-bounded) | — |

**Headline:** nobody on Robinhood Chain (or anywhere found) combines regime-priced dynamic
fees + shaped pooled liquidity + risk-tranche share classes + emissions gated to the
managed layer. Closest neighbor Arrakis serves issuers, not LP depositors. The two
protocols that tried adjacent pieces died of, respectively, **withdraw-rounding accounting**
(Bunni — our R-17) and **unbounded guard parameters** (Gamma — our deposit path); both
failure modes are process/accounting, not concept.

---

## 3. Distilled lessons → FERA requirements

1. **Bunni:** rounding-direction invariant + cumulative-dust bound + micro-withdrawal
   attack PoC on per-tranche accounting (R-17, INV-15).
2. **Gamma:** deposit guards live or die on parameter bounds — hardcode legal ranges for
   the TWAP-deviation threshold; ratio-matched deposits; no off-chain config authority.
3. **Veda:** post-mint share lock (= `DEPOSIT_COOLDOWN_SEC`) and bounded NAV movement are
   shipped, battle-tested patterns — adopt both.
4. **Charm:** drip can deploy single-sided fee income as a limit band instead of swapping —
   removes drip's swap cost and MEV surface entirely.
5. **OZ hooks:** fee-forfeiture beats remove-blocking for JIT defense — never blocks exits
   (INV-11-compatible), directly confiscates the JIT motive; needs after-liquidity +
   return-delta flags (address re-mine).
6. **Maverick + sim:** liquidity must follow price (demand is proven), but *principal*
   moves churn IL in chop — follow with income by default, move principal only under
   guarded triggers (see ARCHITECTURE_REVIEW (b)).
7. **Cork:** hook access control (`msg.sender == poolManager`, pool-key binding) is the
   most-exploited v4 surface — belongs in the Security test plan.
8. **BarnBridge:** have legal review the "tranche" framing before GTM uses the word.
