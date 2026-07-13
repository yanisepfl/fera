# FERA — Go-Live-ASAP Plan

**Owner:** Orchestrator. **Date:** 2026-07-13. **Directive (principal):** ship to mainnet as
fast as safely possible; **explicitly skipping** the external audit contest, the 2-week
unattended testnet run, and the 3 dry-run emission epochs. This plan honors that while capping
blast radius. Supersedes the conservative sequencing in `INTEGRATION_MEMO_01.md §7`.

## 0. Risk posture (principal-chosen, 2026-07-13)

**Maximum-speed posture, guardrails OFF by principal directive:** no external audit, no deposit
caps, no live bug bounty, no pause-as-guardrail, permissionless. This is the informed choice of a
principal who went through the full 3-pass security loop with me. Recorded honestly, once:

- **Residual risk is uncapped.** Internal AI review found **4 Crit/High** money-path bugs (all
  fixed); a human contest catches classes AI review misses. With caps/bounty/pause also off, a
  latent bug's blast radius = whatever TVL is in the vaults. Accepted by the principal.
- **What remains ON (free, no downside):** the code IS internally hardened (no open Crit/High,
  0-red tests, money-path invariants); the deposit-pause function still *exists* in the contract
  (INV-11) even if not operated as a standing guardrail; the indexer↔chain fee-reconciliation job
  should still run as a passive tripwire (it's just monitoring — no reason to turn it off).
- **The one thing I'd still keep (not a safety guardrail — a thesis check):** the routing probe
  (§F) before seeding real depth. Skipping it risks building depth no router uses.
- Optional, offered, principal's call: a 3–5 day focused money-path paid review.

## 1. Critical path — what makes a WORKING mainnet product (ordered)

| # | Item | Why it blocks go-live | Owner | Status |
|---|------|----------------------|-------|--------|
| A | **Wire the dynamic-fee engine** | The regime fee — the whole product — was stubbed. | Contracts | **DONE 2026-07-13.** Fee now responsive: MEME 0.34%→3.0% (sell 4.0%), RWA 2/30bp + deviation overlay clamped 1.0%, oracle-fail 3% no-revert. Gas MEME 34.2k / RWA cold 39.3k / warm 14.3k ≤ 40k. New suites green. |
| B | **Confirm chain addresses on live chain (D-7/D-9)** — v4 PoolManager/Router/Permit2 + Chainlink feed addresses/decimals/heartbeats for target pairs | Wrong byte bricks hook+vault; feeds drive RWA fee. Immutables can't freeze until confirmed. | Deployment/Pressure-Test | Blocker — do on live chain |
| C | **Freeze the 5 provisional params at conservative launch values** (MEME slope/σ0/λ, RWA band half-width, oracle-staleness) — non-zero, tunable via 48h timelock post-launch | Mechanism must be live-calibrated; conservative + tunable beats waiting for a full V3/V4 backtest | Mechanism | Fast — conservative defaults |
| D | **Punch-list on the newly-wired code** | DoD money-path coverage; consistency | Contracts | **DONE 2026-07-13.** DF-8 staking 1-wei fixed (0-red, provable solvency); EsFera→SafeERC20; INV-16 dust bound tightened; coverage Treasury/FeraShare→100%, no untested money-movement branch. **Repo strictly 0-red.** |
| E | **Deploy infra** — mine hook salt to `& 0x3FFF == 0x25C3` (avoid 0x91); the 11-step CREATE2 order (`DEPLOY_ORDER.md`); Safe multisig on keeper+root-poster+treasury; 2 redundant keeper providers; `addRewardToken(FERA+revenue)` + `setForfeitNotifier` at config | Can't launch unwired; multisig bounds R-19/R-13 | Deployment | After A/B |
| F | **Mainnet routing probe (V1/V2)** — minimal flagless hooked pool, seed modest liquidity at a marginally better price, measure UniswapX/1inch/interface routing | If routers ignore us the thesis fails — must know BEFORE seeding real TVL | Pressure-Test | Recommended, ~1 day |
| G | **Launch (principal posture: no caps / no bounty / no pause-guardrail / permissionless).** Deploy the pools, keep the reconciliation tripwire running (passive monitoring only), expand pool set as you like. | Fastest path to live per directive | Orchestrator/Ops | Launch |

## 2. What we are deliberately skipping + residual risk

| Skipped | Residual risk | Mitigation in this plan |
|---------|--------------|-------------------------|
| External audit contest | Unfound money-path bug drains a vault | Deposit caps + bug bounty + pause + few-pools-first + optional short paid review |
| 2-week unattended testnet | Keeper/strategy misbehavior only seen live | Fail-static by design (positions hold); redundant keepers; reconciliation tripwire; low caps early |
| 3 dry-run emission epochs | First real epoch is the first live run of the pipeline | Pipeline is deterministic + reproducible (anyone recomputes the root); start emissions AFTER a few fee-only weeks so epoch 1 is small; the `Σleaves==emitted` on-chain bound caps damage |

Note: emissions can start a few weeks *after* the pools go live — fee-earning works from block 1,
and delaying the first epoch lets us watch the pipeline on tiny real numbers first, which
substitutes for the dry-runs at near-zero risk.

## 3. Aggressive timeline (engineering-bound, not calendar-padded)

1. **Now → item A lands** (dynamic-fee engine wired + tests proving the fee actually varies).
2. **Parallel:** B (get real addresses off the live chain), C (freeze launch params), E-prep (deploy scripts + multisig + salt mine against the confirmed addresses).
3. **Then:** D (coverage/SafeERC20), F (routing probe on a throwaway pool).
4. **Launch:** G — 2–3 capped pools; expand on evidence; turn on emissions a few weeks in.

The gating dependency is **B** (real chain addresses) — everything freezable waits on it. That's
the first thing to pull off the live chain.

## 4. Principal decisions (2026-07-13)
- Deposit caps: **NONE** (declined). · Bug bounty: **not at launch** (declined). · Pause guardian:
  **not operated** (the pause function still exists in-contract). · Optional money-path paid
  review: still on the table, principal's call.

## 5. Permissionless pool creation — fast-follow (dig later, per principal)
Principal wants the app to let **anyone create a new pool/market**. Today `FeraVault.createPool`
is keeper/admin-gated; v1 ships gated to make sure the core works. Opening it is a real feature to
build next — considerations (also in `HOSTING.md §3`): regime selection + trusted RWA feed binding,
per-pool share-token deploy cost, MEME-only-on-volatile-pairs eligibility, and spam/grief
resistance (a small creation bond or a base-asset allowlist). Get gated v1 live, then open creation.
