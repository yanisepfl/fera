// STAND-IN for the file `ponder codegen` normally generates.
//
// WHY THIS EXISTS: `ponder codegen` derives precise types for the `ponder:*` virtual modules
// from ponder.config.ts + ponder.schema.ts, but it requires a Postgres/RPC-connected build
// step. This repo's build-runbook (README) forbids long-running / connecting commands during
// offline typecheck, so we ship these loose ambient declarations to let `tsc --noEmit` pass
// WITHOUT codegen. In CI (with the DB up) run `npm run codegen` — it OVERWRITES this file with
// the fully-typed version, giving strict typing on `db`/`schema`/event args. Nothing here
// weakens the strongly-typed pipeline/, api/serialize, keepers, or ops code.

declare module "ponder:registry" {
  // The real type is Virtual.Registry<config, schema>; loose here so handlers still compile.
  export const ponder: {
    on: (name: string, fn: (args: { event: any; context: any }) => unknown) => void;
  };
}

declare module "ponder:schema" {
  const schema: any;
  export default schema;
}

declare module "ponder:api" {
  import type { PublicClient } from "viem";
  // Read-only drizzle handle over the indexed store (real type: ReadonlyDrizzle<schema>).
  export const db: any;
  // One viem PublicClient per configured chainId.
  export const publicClients: Record<number, PublicClient>;
}

declare module "ponder:internal" {
  export const config: any;
  export const schema: any;
}
