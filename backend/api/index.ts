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
import { cors } from "hono/cors";
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

// CORS: guarantee browser access from the frontend origins (FERA_ALLOWED_ORIGINS,
// comma-separated; default = local frontend dev origin). NOTE Ponder 0.9's server already
// wraps every route in `cors({ origin: "*" })` (ponder/dist/esm/server/index.js), so this
// inner allowlist cannot RESTRICT below `*` today — it pins the explicit origins (and keeps
// the allowlist semantics if Ponder ever drops its wildcard). Data here is public/read-only
// and credential-less, so `*` is not a data-exposure issue; rate limiting belongs at the
// reverse proxy in production.
const allowedOrigins = (process.env.FERA_ALLOWED_ORIGINS ?? "http://localhost:3000")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
app.use("*", cors({ origin: allowedOrigins, allowMethods: ["GET", "OPTIONS"] }));

mountRoutes(app, { store, liveFee });

export default app;
