# Backend (Agent 4) — Open Decisions & Interface Flags

Backend-local decision log. Rows that touch a **shared** surface (§6/§8/§9) are raised to the
Orchestrator per MASTER_SPEC §12/§13; rows prefixed `D-BK-*` are backend-internal dependency flags.
This file is the backend's row in the §13 process — the Orchestrator reconciles into MASTER_SPEC.

---

## Confirmations requested by the Orchestrator

### D-2 — API is REST/JSON (not tRPC). **CONFIRMED by Backend.**

The API ships **REST/JSON**, and the §8 shapes are the contract (concretely frozen in
`api/shapes.ts`). Rationale:

- The consumer set is broader than one TypeScript frontend: the reproducibility story (§8/§9) means
  wallets, explorers, dashboards, and independent re-builders all read these endpoints. REST/JSON is
  language-agnostic and cacheable at the edge; tRPC's value (end-to-end TS types, RPC batching) is a
  single-client convenience we don't need and would couple the Frontend to Backend's TS types.
- Ponder serves a Hono app natively (`src/api/index.ts` → `api/`), so REST is zero-friction; the
  Frontend can still generate a typed client from `api/shapes.ts` if it wants type-safety.
- The live dynamic fee is served with a **read-through cache, TTL ≤ ~1s** (`api/liveFee.ts`,
  `FERA_LIVE_FEE_TTL_MS` default 1000ms) with an indexed fallback — satisfying §8 "TTL ≤ block time".

**No change to §8 requested.** One intentional superset is flagged as D-BK-3 below.

### D-3 — `Swap.feeAmount` in the INPUT token → USD via feeds. **CONFIRMED by Backend.**

Backend consumes `feeAmount` as the LP fee in the **input token** (token0 when `zeroForOne`, else
token1) and converts to USD via per-token feed prices. Integer-only valuation (`src/lib/prices.ts`,
`valueE6`); USD carried as E6 micro-dollars end-to-end. Two separate price paths, by design:

- **Display path** (`api/`, `ops/`): may read **live** feeds — numbers are display-only, never posted.
- **Consensus path** (`pipeline/`): uses a **pinned per-epoch price snapshot**, never a live read, so
  the Merkle root is reproducible.

Gas cost of the compact event is already resolved in Backend's favor by Mechanism **DM-5** (the
`feeAmount`+`lpFeePips` LOG fits the ≤40k hook budget, ~3.1k for the LOG). **No change to §6 requested.**

---

## Consensus-pipeline invariants the Orchestrator asked Backend to verify

### D-M8 — normative pipeline ordering. **IMPLEMENTED (pipeline v3, `fera-emissions-pipeline/3`).**

`pipeline/emissions.ts` now follows MECHANISM_SPEC §4.4 exactly (see `pipeline/README.md` §5):

1. fixed epoch envelope `E = min(cap, β·ΣR_p/twap)` (INV-7);
2. per-pool `E_p = min(capShare_p, β·R_p/twap)` — the per-pool revenue lock is **FINAL** and
   holds after any boost weighting (PT-5). `capShare_p = cap·Q_p/ΣQ`, `Q_p = R_p·divMult_p`
   with divMult over **cluster-collapsed** unique traders (PT-9). A pool bound below its cap
   share leaves FERA **un-emitted** — never redistributed to other pools;
3. **85/5/10** split (Decision-A″ frozen, F-10) **within each pool**;
4. LP leaf = self-match-excluded fees-earned weight × boost, normalized **within the pool**
   (boost can never import emissions across pools); trader leaf pro-rata fees paid, no boost
   (Decision B), cluster-share ≥5% traders zeroed.

Dry-run asserts: conservation (`Σ leaves + treasury == emitted == Σ E_p`, per-pool
`trader+lp+treasury == E_p`), the double lock post-boost, exact 85/5/10 legs, and two
counterfactual runs — no-boost (trader leaves byte-identical; per-pool LP totals identical)
and no-cluster (excluded self-dealer strictly under his unexcluded capture). **PT-5 holds by
construction; PT-2's cross-pool boost import channel is structurally closed.**

### INV-13 — funding-cluster self-match exclusion. **LIVE (was wired-but-inert).**

Mechanism froze the method (PARAMS.md `SELF_MATCH_*`, MECHANISM_SPEC §4.7); the pipeline now
**computes** the exclusion from the frozen snapshot as a consensus-versioned stage
(`pipeline/cluster.ts`, algorithm stated precisely in `pipeline/README.md` §4):

- cluster = connected components of (first-funder graph, depth ≤ 2) ∪ (vault-share
  transfers), deterministic (lowercased, sorted, smallest-address representative);
- LP leaf: `excluded = lpWeight × clusterFeesPaid/poolFeesPaid` (epoch-granular) — the
  excluded portion earns **zero** emissions (base AND boost);
- trader leaf: zeroed when the trader's cluster holds ≥5% of the pool's vault shares
  (time-weighted share-seconds, max across tranches);
- stance **default-allow**: router/solver/settlement traders are unclusterable and count as
  external (evasion friction, not a bound — honest residual documented in INV-13/D-M9).

**Semantics note (spec reconciliation):** the original inert hook excluded self-flow from the
boost *premium* only (1x rate on excluded weight). MASTER_SPEC v0.6 §9 froze the STRONGER
reading — "caught ⇒ **zero emissions** on that flow" — and MECHANISM_SPEC §4.5 defines
`lpWeight` as *self-match-excluded*. The pipeline implements the spec (full weight
exclusion); the historical field name `boostExclusionE6` is kept for interface continuity
(it is now an OUTPUT computed by the pipeline and published in the bundle, no longer a
snapshot input). Flagged for D-M9 Security co-sign visibility.

**Snapshot-builder dependency (D-BK-11 below):** the cluster stage consumes `fundingEdges`
(first-funder graph since genesis) and `shareTransfers` (vault share ERC-20 Transfers) —
neither is a §6 event. Share `Transfer`s come from the per-pool share ERC-20s (addresses
known from the Vault); the first-funder graph needs a chain-scan service outside Ponder's
§6 event set. Until wired, production snapshots that omit them get `SELF_MATCH_EXCLUSION`
vacuously (no clusters ⇒ no exclusions) — default-allow degrades safely but silently; the
root-poster should refuse mainnet epochs without a pinned funding graph.

---

## D-BK-* — backend-internal dependency flags

| # | Flag | Impact | Status |
|---|------|--------|--------|
| D-BK-1 | `abis/` are MINIMAL reconstructions from §6 v0.6 (incl. the F-8 batch) + ASSUMED view/write fragments (`getDynamicFee`, `isMarketOpen`, `setHolidayFlag`, `setEventWindowFlag`, `isEventWindow`, `executeStrategy`, `accruedFees`, `postRoot`, `rootOf`, `boostOf`, `currentEpoch`, `latestRoundData`). Contracts v2 artifacts not landed (parallel contracts agent refactoring — do NOT read contracts/ mid-flight). | API live-fee, keepers, reconcile depend on these signatures being right. | **Open (BK-1)** — replace with `contracts/out/*.json` and diff vs §6 when the v2 artifacts land. |
| D-BK-2 | F-8 `PoolRegistered(poolId, token0, token1, regime)` is now indexed (handler implemented; `pool.registered` marks event-sourced rows) — closes the BK-2 interface gap. The event carries no decimals/symbols, so env `FERA_POOL_TOKENS` / `FERA_TOKEN_META` remain the metadata fallback. | `/pools` token metadata quality. | **Open (narrowed)** — follow-up: read `decimals()`/`symbol()` from the ERC-20s at registration (RPC in handler). |
| D-BK-3 | `/epochs/:id/proof/:account` returns a **list** `{ root, claims:[{kind,amount,proof}] }`, a superset of §8's singular `{ kind, amount, proof[] }`. | An account may hold BOTH a trader-rebate (kind 0) and an lp-reward (kind 1) leaf; returning both in one call avoids a second round-trip. `?kind=0\|1` filters. | **Accepted** (§8 updated per BK-3). |
| D-BK-4 | `/pools/:poolId/depth` `depth1PctUsd` is a **liquidity-based approximation** (single-range amount to move price ±1%), not an exact tick-bitmap walk; FERA-pool depth is approximated by TVL as a conservative lower bound. | Marketing/comparison number (V4). Conservative (never overstates FERA depth). | **Open** — upgrade to exact cross-tick depth pre-mainnet. |
| D-BK-5 | `/positions/:account.emissionsPending` returns `"0"` (placeholder). | Live projection of not-yet-posted esFERA per LP needs the pipeline's in-epoch partial run wired into the API. | **Open** — wire the snapshot-builder's live projection; documented, non-blocking. |
| D-BK-6 | Offline `tsc` scopes out `src/handlers/**` (Ponder codegen types need the DB). | Handlers are typechecked by `npm run typecheck:ponder` in CI, not offline. | **Accepted** — consistent with the pre-existing `typecheck` / `typecheck:ponder` split. |
| D-BK-7 | §6's F-8 batch does not name the contract emitting `JitPenaltyApplied`. Backend indexes it on **FeraHook** (the D-14 OZ `LiquidityPenaltyHook` pattern forfeits in `afterRemoveLiquidity` — a hook concern, not a vault one). | If Contracts emit it from the Vault instead, move the handler + ABI fragment (5-line change). | **Open** — confirm with Contracts on v2 artifact landing. |
| D-BK-8 | MECHANISM_SPEC §3.1.4 assigns the guarded MEME principal recenter `StrategyAction kind=6`, but MASTER_SPEC §6 (F-8) only registers `kind=5` (dripDeploy). The indexer stores `kind` raw, so 6 will index fine; the §8 strategyLog legend and ABI comment stop at 5. | Cosmetic/legend drift only. | **Open** — needs an Orchestrator §6 edit registering kind 6. |
| D-BK-9 | `/vesting/:account.claimable` is served as `vested`: §6 has **no per-grant claim event** (no `VestClaimed(grantId, amount)`), so claimed-to-date is not indexable. `InstantExit` also carries no grantId. | Frontend shows gross vested as claimable until a claim event exists. | **Open** — candidate §6 addition `VestClaimed(account, grantId, amount)`; needs Orchestrator sign-off. |
| D-BK-10 | §8 conventions v0.2 audit: APR/APY fields were rendered as **percent** strings ("12.00") — now fixed to **decimal fractions** ("0.1200"); `token0`/`token1` on pool items changed from bare addresses to the `{address, symbol, decimals}` object shape. Both are conforming-but-breaking vs the previous backend build. | Frontend consumers of the old shapes must update (they were spec-violating shapes). | **Done** — flagged for Frontend visibility. |
| D-BK-11 | The §4.7 cluster stage consumes `fundingEdges` (first-funder graph since genesis) + `shareTransfers` (share ERC-20 Transfers) — **neither is a §6 event**. Share Transfers are indexable once share-token addresses are known (vault clone registry); the funding graph needs a chain-scan/tracer service. A snapshot omitting them yields NO clusters ⇒ no exclusions (default-allow degrades silently). | Consensus-critical input provenance. | **Open — gates mainnet epochs**: root-poster must refuse a mainnet epoch whose snapshot lacks a pinned funding graph + share-transfer set. |
| D-BK-12 | D-M8 makes `emitted = Σ_p E_p` (per-pool locks final) potentially **strictly less** than `min(cap, β·rev)`. `EpochFinalized(emitted)` on-chain must report the same quantity the pipeline computes, and the controller must fund the Distributor with `totalEsFera = Σ leaves` (≠ emitted; treasury leg funded directly). | Controller/pipeline accounting alignment (INV-7 test vector). | **Open** — confirm with Contracts; the bundle now carries both `epochTotalFeraWei` and `emittedFeraWei` to make the distinction auditable. |

---

## Interface-drift check vs §6 / §8 (as of the v2 refactor batch)

- **§6 events (v0.6, incl. F-8)** — schema + handlers index the frozen signatures PLUS the F-8
  batch: `PoolRegistered` (event-sourced pool metadata, env fallback kept), `uint8 tranche` on
  `Deposit`/`Withdraw`/`FeesCollected`/`SharePriceCheckpoint` (per-tranche positions/state
  throughout schema/store/API), `StrategyAction kind=5` dripDeploy + `kind=6` bandConsolidate
  (both are fee-band ops → do NOT overwrite the principal band range; BK-1 reconcile closed the
  kind=6 legend gap D-BK-8), `JitPenaltyApplied` (indexed + pool-level forfeited-fees-to-LPs
  metric — it's LP yield; **contracts/out confirms the hook is the emitter — D-BK-7 CLOSED**),
  `EsFera.VestClaimed` (BK-1 — now indexed, `schema.vestClaimed` + handler).
- **§8 endpoints (conventions v0.2)** — all ten implemented incl. the new
  `GET /vesting/:account` (F-3: `[{grantId, amount, startTs, endTs, vested, claimable}]`, wei
  strings). Conventions audit: FERA/esFERA/raw amounts are raw 18-dec integer strings; APRs now
  decimal fractions (D-BK-10 fix); token embeds now `{address, symbol, decimals}` objects;
  timestamps unix seconds; fees pips. Additive: `tranches[]` on pool items, `tranche` on
  positions, `jitFeesForfeitedToLpsUsd` on pool detail, `currentFeeSource` provenance,
  proof-list superset (D-BK-3).
- **§9 pipeline (D-M8)** — Merkle leaf `keccak256(abi.encode(epochId, account, kind,
  amount))`, sorted-pair hashing, esFERA 18-dec: **unchanged**. Ordering, split, funding-cluster
  exclusion, PT-8 TWAP implemented per v0.6. **F-10**: split 80/10/10 → **85/5/10** (Decision-A″);
  algorithm version bumped to `fera-emissions-pipeline/3`, scriptVersionHash changed (posted-epoch
  bundles keep theirs). Deterministic root re-verified — dry-run all-pass, byte-identical bundle +
  root `0xcc00c791115af886a60364bf7d5c7dab8d11120245fea6ebf5db1581c6897e78` across two runs.

---

## F-10 / F-11 / BK-1 — contracts v2 catch-up (2026-07-12). **DONE.**

### F-10 — emission split 80/10/10 → 85/5/10 (Decision-A″). **DONE.**

`pipeline/config.ts`: `SPLIT_LP_BPS 8000→8500`, `SPLIT_TRADER_BPS 1000→500`, `SPLIT_TREASURY_BPS
1000` (unchanged). Propagated to all comments/labels/fixtures (`emissions.ts`, `types.ts`,
`dryrun.ts` — incl. a new hard assertion pinning `8500/500/1000` & sum==BPS), the `emissionsApr`
LP-share constant in `api/store.ts` (8000→8500), `pipeline/mocks/events.ts`, and the READMEs.
`PIPELINE_ALGO_VERSION` bumped `/2 → /3` (consensus change → new scriptVersionHash). Dry-run
legs now 5% trader / 85% LP / 10% treasury; conservation + double-lock + counterfactuals all pass.

### F-11 — controller funds exactly ΣE_p via `finalizeEpoch(emissionRequested, …)`. **DONE.**

`contracts/out/EmissionsController.json` signature:
`finalizeEpoch(uint256 epochId, uint256 emissionRequested, uint256 revenueValuedInFera, uint256 feraTwap) → uint256 emitted`.
The root-poster keeper now calls it **before** `postRoot`, passing
`emissionRequested = totalEsFeraWei` (= Σ leaf amounts = trader+lp legs), `revenueValuedInFera =
revenueValuedInFeraWei` (new `EpochResult`/bundle-headline field), `feraTwap = feraTwapE6`.

**ΣE_p semantics (D-BK-12 / R-19) — resolved against the contracts:** the controller mints
`emitted == emissionRequested` as esFERA backing and records `emittedOf[epochId]`; `Distributor.
postRoot` reverts unless `totalEsFera == emittedOf` (R-19). `postRoot`'s `totalEsFera` is the Merkle
leaf sum (`totalEsFeraWei`), so `emissionRequested` MUST equal it — the on-chain "ΣE_p"/`emitted`
is Σ leaf amounts (trader+lp). The **treasury 10% leg is funded directly, OUTSIDE the Distributor
path, and is deliberately excluded** from `emissionRequested` (else `EmittedMismatch`). Because
per-pool locks are final this may be strictly below `min(cap, β·rev)`; INV-7 is an inequality so
funding exactly the committed total (no envelope padding) is compliant (D-BK-12). Keeper is
idempotent: if the epoch is already `finalized`, it asserts `emittedOf == emissionRequested` (else
aborts on snapshot drift) rather than re-finalizing.

### BK-1 — ABI reconcile vs `contracts/out/*.json` v2. **DONE (with flagged residual).**

Artifacts ARE present (`contracts/out/*.sol/*.json`). Diffed every event I index + every function
I call:

- **EVENTS — all match on-chain** (verified field order + types): `Swap`, `PoolRegistered`,
  `JitPenaltyApplied` (FeraHook); `Deposit`/`Withdraw`/`FeesCollected`/`SharePriceCheckpoint` with
  `uint8 tranche` as the **LAST** field + `StrategyAction` (no tranche) (FeraVault); `RootPosted`/
  `Claimed` (Distributor); `VestStarted`/`InstantExit`/`ForfeitRouted` + **`VestClaimed`** (EsFera —
  was MISSING, added to ABI + schema + handler); `Staked`/`Unstaked`/`RevenueShareClaimed`
  (AnchorStaking); `RevenueReceived`/`RevenueSplit` (RevenueDistributor); `EpochFinalized`
  (EmissionsController). StrategyAction `kind=6` bandConsolidate confirmed registered.
- **FUNCTIONS fixed:** EmissionsController — `epochEndsAt` → real `epochEnd`; added `finalizeEpoch`
  (F-11), `finalized`, `emittedOf`, `capAt`, `beta`. AnchorStaking — `boostOf` now `pure`
  (`boostWad`); removed phantom `multiplierPoints` getter (not on-chain); added the v2 revenue-share
  **allowlist** reads `isRewardToken`/`rewardTokenCount`/`rewardTokens`/`claimableRevenue` +
  `stakedOf`/`lockUntil`/`totalStaked`. FeraHook — added real `regimeOf`.
- **⚠️ RESIDUAL DRIFT (flagged, NOT auto-fixed — routed to Contracts + Backend keeper follow-up):**
  the RWA keeper read/write surface has **no on-chain counterpart**. On-chain the FeraVault v2 has
  writes `setHoliday`/`setEventWindow`/`recenter`/`recenterMeme`/`widen`/`drip`/`collectFees` and
  reads `pendingFees(id,t)`/`regimeOf(id)` — but **NO** `isMarketOpen`/`isEventWindow`/`getDynamicFee`
  VIEW getter and **NO** generic `executeStrategy`. The `marketHours`/`rwaStrategy`/`eventCalendar`
  keepers + `ops/reconcile` + `api/liveFee` still reference the ASSUMED names (`isMarketOpen`,
  `setHolidayFlag`, `executeStrategy`, `isEventWindow`, `setEventWindowFlag`, `accruedFees`,
  `getDynamicFee`). Kept as-is so the backend compiles; these need (a) Contracts to add the missing
  view getters, or (b) a keeper rewire to derive market/event state from indexed
  `setMarketOpen`/`StrategyAction` events + read the live fee via v4 StateLibrary slot0. **This is
  the only open item from the catch-up.**

### §8 API audit. **CONFIRMED — no drift.**

`/vesting` present with the frozen shape; tranche fields on `/pools` + `/positions`; all FERA/esFERA
amounts are raw 18-dec integer strings; APRs decimal-fraction strings; USD pre-scaled; token embeds
`{address,symbol,decimals}`. `VestClaimed` now indexed (account-level); per-grant `claimable`
remains an approximation (event carries no grantId — D-BK-9). No §8 shape change.
