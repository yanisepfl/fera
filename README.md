# FERA

**Regime-aware liquidity infrastructure on Robinhood Chain.**

FERA deploys Uniswap v4 pools priced by a dynamic-fee hook and owned by a managed
Vault. It competes for the chain's already-routed volume by making LPs earn strictly
more per dollar than anywhere else — monetizing *all* flow (human, bot, arb, wash)
through fees that price toxicity instead of bleeding to it.

> One flagless v4 hook (open swaps, gated liquidity) + one per-pool managed Vault +
> a usage-only emission token whose issuance can never exceed protocol revenue.

## Status

Greenfield. This repo is being built from the **FERA Mission Pack v2** (locked design).
The single source of truth for all shared interfaces, event schemas, accounting
constants, and the definition of done is [`docs/MASTER_SPEC.md`](docs/MASTER_SPEC.md).
Read it before touching any cross-component surface.

## Repository map

| Path             | Owner (mission-pack agent) | Contents |
|------------------|----------------------------|----------|
| `docs/`          | Orchestrator (0)           | Master spec, chain due-diligence, integration memos |
| `docs/mechanism/`| Mechanism (1)              | Frozen math spec, parameter table, runnable Python sims |
| `contracts/`     | Smart Contracts (2)        | Foundry project: hook, vault, token, emissions, staking |
| `frontend/`      | Frontend (3)               | Next.js app + `DESIGN.md` design system |
| `backend/`       | Backend (4)                | Ponder indexer, API, emissions pipeline, keepers |
| `pressure-test/` | Pressure-Test (8)          | Numbered validation memos + backtest/attack harnesses |

Deployment/DevOps (5), Security (6), and GTM (7) are continuous and contribute across
`docs/`, `contracts/`, and CI configuration.

## Design invariants (never violate without written escalation to Orchestrator)

1. **Swaps are never gated and never charged a protocol fee** — any router/aggregator/bot
   may swap permissionlessly. Liquidity mutation is gated to the Vault only.
2. **Traders (incl. bots) pay zero protocol fees.** LPs pay a 10% performance fee only on
   yield they earn, taken at fee-collection time — never on principal, swaps, or deposits.
3. **MEME vault positions are full-range and never rebalanced.** RWA positions recenter
   only on oracle hysteresis, during market hours, TWAP-sanity-checked.
4. **Emissions ≤ min( logistic cap(t), β × epoch revenue )** every epoch. A dividend of
   activity, not a subsidy.
5. **No upgradeable proxies on money paths.** Params are immutable or behind a 48h timelock.
   Pause is allowed on Vault *deposits* only — never on swaps or withdrawals.

See `docs/MASTER_SPEC.md` §"Locked design invariants" for the full, testable list.
