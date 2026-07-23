# Developers

This page orients a developer or integrator in the FERA repository. It points at the authoritative
specs rather than restating them. Those documents are the source of truth and are kept in the repo.

## Architecture in one picture

```
        traders / routers / bots
                  │  swap (never gated, no protocol fee)
                  ▼
        ┌───────────────────────┐        Chainlink feeds (RWA)
        │  Uniswap v4 PoolManager│◄───────── price / market-hours
        └──────────┬────────────┘
                   │ beforeSwap → dynamic fee   (MEME: vol-scaled | RWA: drift-scaled)
                   ▼
             ┌───────────┐        deposits / withdrawals        ┌──────────────┐
             │ FeraHook  │◄────────────────────────────────────►│  FeraVault   │  wide base + limit
             └───────────┘   fee checkpoint / JIT forfeiture    │  + FeraShare │  + idle, risk profiles
                                                                └──────┬───────┘
                                                                       │ 10% performance fee (revenue)
                            ┌──────────────────────────────────────────┼───────────────────────────┐
                            ▼                                          ▼                            ▼
                    RevenueDistributor                        EmissionsController → Distributor → EsFera
                    (50% stakers / 25% treasury / 25% ops)     (min(cap, β·revenue) → 85/5/10 → Merkle root)
                            │                                                            │
                            ▼                                                            ▼
                      AnchorStaking (sFERA: LP-emission boost + revenue share)     FeraToken (fixed 1B)
```

Off-chain: a **Ponder indexer + API** reads on-chain events and serves the frontend; a **deterministic
weekly emissions pipeline** computes the Merkle root and a reproducibility bundle; **keepers** run
market-hours, RWA strategy, oracle-staleness, event-calendar, and root-posting jobs.

## Repository layout

| Path | Contents |
|------|----------|
| `contracts/` | Foundry project: the hook, vault, token, emissions, staking, treasury. Money-path Solidity. |
| `backend/` | Ponder indexer, REST/JSON API, the consensus-critical emissions pipeline, keepers, ops. |
| `frontend/` | Next.js app. |
| `docs/gitbook/` | This documentation set (GitBook-synced). |
| `docs/mechanism/`, `docs/research/` | Runnable fee-math sims and backtest data supporting the docs. |

## The contracts

Ten money-path contracts under `contracts/src/`:

| Contract | Role |
|----------|------|
| `FeraHook.sol` | Uniswap v4 hook: sets the per-swap dynamic fee, checkpoints fees, enforces the anti-JIT forfeiture. |
| `FeraVault.sol` | Managed vault: wide vol-adaptive base + near-price limit + idle reserve, risk profiles, deposit/withdraw, swap-free limit-fill with a rare, IL-capped base re-anchor. |
| `FeraShare.sol` | ERC-20 share token per pool/profile. |
| `FeraToken.sol` | FERA: fixed 1,000,000,000 supply, no inflation knob. |
| `EsFera.sol` | Escrowed FERA: linear 6-month vest, 50% instant-exit haircut with the 3-way forfeit split. |
| `EmissionsController.sol` | Enforces `emitted ≤ min(cap(t), β × revenue)` each epoch. |
| `Distributor.sol` | Merkle-root emission claims; caps cumulative claims at the funded envelope. |
| `AnchorStaking.sol` | Staking (sFERA): LP-emission boost + multi-token revenue share (curated allowlist). |
| `RevenueDistributor.sol` | Splits the 10% performance-fee revenue 50/25/25 (stakers/treasury/ops). |
| `Treasury.sol` | Protocol treasury behind a 48-hour timelock. |

Design invariants (swaps never gated/fee'd, withdrawals never pausable, no upgradeable proxies on
money paths, emissions ≤ min(cap, β·revenue)) are verified by the invariant test suites under
`contracts/test/`.

## Build & test

Foundry, Solidity 0.8.26, Cancun:

```bash
cd contracts
git submodule update --init --recursive   # deps are pinned submds; do NOT run `forge install`
forge build                                # ~120s first build (canonical v4 optimizer_runs)
forge test                                 # unit + hook + integration + invariant suites
forge test --gas-report                    # hook beforeSwap+afterSwap ≤ 40k gas budget
slither . --config-file slither.config.json
```

Backend (Node ≥ 20, Ponder):

```bash
cd backend
npm run typecheck
npm run dev                # indexer + API
npm run pipeline:dryrun    # deterministic emissions pipeline over mocked events + invariant checks
```

CI gates (build/lint, unit + branch coverage, invariants/fuzz on an anvil mainnet-fork, the ≤40k gas
budget, hook-address check, static analysis) are in `.github/workflows/`.

## Chain & deployment

FERA targets **Robinhood Chain** (mainnet chain ID **4663**, testnet **46630**), an Arbitrum Orbit
L2, ETH for gas, ~100 ms soft blocks, FCFS sequencing, Chainlink as the chain's oracle infra.

- **The hook is CREATE2-deployed** at a salt-mined address whose low 14 bits encode its permission
  flags (target `address & 0x3FFF == 0x25C3`). The salt is bound to the constructor args, so it must
  be mined *after* the PoolManager address is confirmed.
- Chain facts, canonical addresses, and the step-by-step deploy sequence are kept privately by the
  team.

## Where to read next

- The fee math: [How the dynamic fee works](how-fees-work.md).
- The security review: [Security](security.md).

---

Next: [Security →](security.md) · [Transparency →](transparency.md)
