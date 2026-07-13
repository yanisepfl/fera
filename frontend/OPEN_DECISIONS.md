# Frontend — Open Decisions & §8 Interface-Drift Flags

Assumptions the frontend makes about the **Indexer → API data contract**
(`MASTER_SPEC §8`) that Backend (4) must confirm or correct. §8 says the shapes are
"illustrative, Backend owns final" — so where the UI needs a field §8 doesn't spell
out, we chose a minimal shape (mirrored in `lib/types.ts`) and flagged it here.

Per the §12 interface-change protocol, any change to a §8 field name/type is routed
through the Open Decisions log; these are the frontend's inputs to that.

| # | Area | §8 says | Frontend assumes | Drift risk | Owner |
|---|------|---------|------------------|-----------|-------|
| **OD-1** | Token metadata | `token0`/`token1` (bare). §6: amounts raw, Backend applies decimals. | `/pools` embeds `Token = { address, symbol, decimals }` so the UI renders a pair with **no second lookup**. | Low — Backend already holds metadata; just needs to embed it. | Backend |
| **OD-2** | `PoolDetail` extra fields | "incl. position band, marketHoursState (RWA), oraclePrice, poolPrice, feeHistory[], strategyLog[]" — not every field named. | Field names invented within that latitude: `band: PositionBand{fullRange, tickLower/Upper, priceLower/Upper}`, `feeHistory[{t, feePips}]`, `strategyLog[{t, kind, tickLower/Upper, oraclePrice, justificationHash, txHash?}]`. | Medium — names/shape must match. | Backend |
| **OD-3** | Units | Units left to Backend. | `*Pips` = hundredths-of-a-bip (§5); `*Apr` = decimal fraction (0.184 = 18.4%); `*Usd` = pre-scaled USD; timestamps = unix **seconds** unless the field ends in `Ms`. | Medium — a units mismatch silently mis-renders every number. | Backend |
| **OD-4** | RWA geo-fence list | Not a §8 field (frontend compliance surface). | `config/geo.ts` blocked/ack lists are **placeholders**. Fence governs only the LP/deposit affordance; swaps are never gated (INV-2). | High — needs a legal-reviewed list before mainnet; resolution source (edge header vs Backend compliance endpoint) TBD. | Orchestrator (legal) / Deployment |
| **OD-5** | esFERA amount precision | `projectedEsFera` (number); `proof.amount` (string). | `ClaimProof.amount` kept as a **string** (18-dec, precision-safe); `projectedEsFera` / `emissionsPending` are treated as **display-rounded numbers**. | Medium — large 18-dec values as JS `number` lose precision; the claimable **string** must be the authoritative one for the tx. Recommend Backend send all esFERA/wei amounts as strings. | Backend |
| **OD-6** | Vesting grants | **No endpoint in §8.** | The Rewards vesting dashboard uses a local `VEST_GRANTS` fixture (esFERA grant → 6-mo linear vest, per-grant instant-exit). | High — a real UI needs `GET /vesting/:account` (or grants embedded in `/staking`). Data gap vs §8. | Backend + Mechanism |
| **OD-7** | Swap quote | **No swap/quote endpoint** (by design — swaps are permissionless on-chain, INV-2). | `/swap` derives the live fee from `currentFeePips` + regime reason and computes an **illustrative** quote client-side (not exact out). | Low — expected; but if exact out is wanted, wire an on-chain v4 Quoter or a read-through quote endpoint. Not a §8 change. | Frontend / Backend |
| **OD-8** | Staker emissions APR | `StakingSummary` has `revenueShareApr` + `boost`; no staker-level emissions APR. | Revenue-share APR (real yield) is rendered **distinctly** from token emissions (per the §8 note); the boost is shown as a multiple on per-pool `emissionsApr`. | Low — confirm whether a staker-level emissions APR should be an API field or stay derived. | Backend / Mechanism |
| **OD-9** | Claimable revenue per token | `StakingSummary` has no per-token claimable revenue. | Stake action is mocked; the panel shows APR, boost, multiplier points, sFERA only. | Low — if the panel should show claimable fee tokens, add `claimableByToken[]` to `StakingSummary`. | Backend |
| **OD-10** | Nullability / 404s | MEME has no market state; not all pairs have a depth comparison. | MEME returns `marketHoursState: null` (present, not omitted) + `band.fullRange: true`; `/pools/:id/depth` may **404** and the UI degrades gracefully. | Low — confirm `null` vs omitted, and 404 vs empty for depth. | Backend |

## v2 catch-up flags (2026-07-11 — pivot alignment; Backend to confirm §8)

| # | Area | §8 / spec says | Frontend assumes | Drift risk | Owner |
|---|------|----------------|------------------|-----------|-------|
| **OD-11** | esFERA/FERA amount type | §8 v0.2: `projectedEsFera`, `emissionsPending`, `vested`, `claimable`, `amount` are 18-dec **strings**. | Changed `Position.emissionsPending` and `CurrentEpoch.projectedEsFera` from `number` → **string**; parse for display only via `format.esFera()`/`weiToTokens()`. Resolves the OD-5 recommendation. | Low — matches §8 v0.2 verbatim; Backend must send strings (previously ambiguous). | Backend |
| **OD-12** | `GET /vesting/:account` | §8: `[{ grantId, amount, startTs, endTs, vested, claimable }]` (added v0.2, FE-6). | Implemented the client + hook (`useVesting`) + MSW handler + fixture. `amount`/`vested`/`claimable` are **strings**. VestingDashboard now consumes it (was a local fixture). | Medium — field names/string types must match. Resolves OD-6. | Backend (follow-up to implement) |
| **OD-13** | Risk classes `tranches[]` | §6 F-8 batch adds `uint8 tranche` to Deposit/Withdraw/FeesCollected/SharePriceCheckpoint (D-12). §8 has no per-class list yet. | Added an **additive optional** `tranches[]` on `PoolSummary`/`PoolDetail` = `{ tranche, riskClass, shareSymbol?, feeApr, emissionsApr, tvlUsd }`, and optional `tranche` on `Position`. RWA → Core+Anchor; MEME → Core only (D-16). When absent the UI treats the pool as single-class Core. | Medium — needs a §8 field for per-class APR/TVL. Naming: user copy uses "Active/Steady", never "tranche" (D-18). | Backend |
| **OD-14** | Band ladder `ladder[]` | §8 `/pools/:id` says "incl. position band"; no discrete-band list. §6 adds `StrategyAction kind=5 dripDeploy` / `kind=6 bandConsolidate`. | Added an **additive optional** `ladder: LadderBand[]` on `PoolDetail` = `{ role, tranche, k?, weightBps?, priceLower?, priceUpper?, isPrincipal, depthMult? }` to draw the Core/Mid/Tail + fee-drip visualization. Added `StrategyKind` 5/6 to the type + strategy-log meta. | Medium — shape invented within §8 latitude; confirm names, or have the UI derive bands from `band` + ladder params. | Backend / Mechanism |
| **OD-15** | Position `lastAddTs` | Not a §8 field. Needed to render the live JIT fee-forfeiture window on Withdraw (INV-1″/D-14). | Added **optional** `lastAddTs` (unix s) on `Position`. Absent ⇒ the disclosure treats the position as freshly-added (worst case, never hidden). | Low — nice-to-have; the deposit-side disclosure is static and needs no data. | Backend |

## Notes

- **v2 pivot numbers baked in:** emission split **85/5/10** (Decision-A″, principal
  2026-07-12; §7 FROZEN — superseded the 80/10/10 working prior and the older 45/45/10),
  MEME fee floor **0.34%** (was 0.30%; `useLiveFee` range floor now 3400 pips). The 85/5/10
  split is reflected in the `EmissionsSplit` component + Rewards/Epoch copy + Earn/Transparency
  page copy (Agent-3 pass, 2026-07-12).
- **D-M13 honesty guardrail (open liquidity):** `OpenLiquidityNote` must never claim the
  vault out-yields direct LPing (measured fee-capture ratio ≤ 0.64; OD-V10). Vault stickiness
  is framed as managed + emissions-eligible + simple. If OD-V10 flips, revisit that copy.

- **INV-13 (boost) is still a candidate (PT-2).** The staking panel's copy already
  reflects the accepted framing (boost re-weights a fixed capped pool, never mints —
  INV-7 / PT-5) and shows revenue-share as the *real* yield. If Mechanism/user pick a
  boost fix that changes how staker emissions are computed, the StakingPanel copy and
  any future staker-emissions-APR field (OD-8) must follow.
- **DM-2 narrative guardrail.** The Earn/Transparency copy markets esFERA as a
  "dividend of activity, not a subsidy" and never presents early usage-emission APR as
  the primary TVL magnet, consistent with DM-2. If that decision flips, revisit the
  Earn hero + Transparency emissions caption.
- Every figure shown is intended to be reproducible from on-chain data via Backend's
  §9 reproducibility bundle. No off-chain "projected APY" is shown without a formula
  link back to the mechanism (§8 rule).
