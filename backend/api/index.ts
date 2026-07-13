// FERA API — Hono app wired to the Ponder store (§8 data contract).
//
// Ponder serves the default-exported Hono app from `src/api/index.ts`; that file re-exports THIS
// app (implementation lives in `api/` per the backend layout). We read the indexed store via the
// readonly drizzle handle `db` from `ponder:api`, the schema from `ponder:schema`, and the live
// dynamic fee via the chain's PublicClient (`publicClients`) through a ~1s read-through cache.
//
// Run:  npm run serve      (ponder serve — API only, reads an already-synced store)
//   or  npm run start      (ponder start — indexer + API together)

import { Hono } from "hono";
import { db, publicClients } from "ponder:api";
import schema from "ponder:schema";
import { Store } from "./store";
import { LiveFeeReader } from "./liveFee";
import { mountRoutes } from "./routes";

const chainId = Number(process.env.PONDER_CHAIN_ID ?? 42161);
const client = (publicClients as Record<number, any>)[chainId];
const hookAddress = (process.env.FERA_HOOK_ADDRESS ?? "0x0000000000000000000000000000000000000000") as `0x${string}`;

const store = new Store(db, schema);
const liveFee = new LiveFeeReader(client, hookAddress);

const app = new Hono();
mountRoutes(app, { store, liveFee });

export default app;
