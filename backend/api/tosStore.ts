// Terms-of-Service acceptance store.
//
// The founder expects a DB of who accepted which ToS version. This is a durable,
// append-only record of signed acceptances kept behind a tiny interface
// (`recordAcceptance` / `hasAccepted`) so it can be swapped for Postgres/Ponder's
// store later without touching callers.
//
// Two zero-dependency backends, chosen at startup (FERA_TOS_STORE = auto|sqlite|jsonl):
//   - sqlite : node:sqlite (Node >= 22.5). A real table + index — preferred when present.
//   - jsonl  : append-only JSON-lines ledger (works on the whole engines>=20 range).
// `auto` (default) prefers sqlite when the runtime exposes node:sqlite, else jsonl.
//
// Both are append-only: an acceptance is a legal record and is never mutated or deleted.
// The signed message + signature are stored verbatim so the record is independently
// verifiable after the fact (recover the address from message+signature).

import { mkdirSync } from "node:fs";
import { appendFile, readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

export interface TosAcceptance {
  /** Lowercased 0x address that the signature was verified to recover. */
  address: string;
  /** ToS version string that was accepted (e.g. "2026-07-16"). */
  version: string;
  /** The exact message the wallet signed (stored verbatim for later re-verification). */
  message: string;
  /** The 0x personal_sign signature over `message`. */
  signature: string;
  /** ISO-8601 timestamp embedded in the signed message (client clock). */
  timestamp: string;
  /** ISO-8601 timestamp the server recorded the acceptance (server clock). */
  recordedAt: string;
  /** Optional hash/URL of the terms bundle embedded in the message (audit aid). */
  termsHash?: string;
  /** Best-effort source IP + UA for the audit trail (never trusted for auth). */
  ip?: string;
  userAgent?: string;
}

export interface TosStore {
  /** Kind of backing store actually in use ("sqlite" | "jsonl"), for /health. */
  readonly kind: string;
  recordAcceptance(a: TosAcceptance): Promise<void>;
  hasAccepted(address: string, version: string): Promise<boolean>;
}

const key = (address: string, version: string) =>
  `${address.toLowerCase()}|${version}`;

// ---------------------------------------------------------------------------
// JSONL: append-only ledger + in-memory index for O(1) status checks.
// ---------------------------------------------------------------------------

class JsonlTosStore implements TosStore {
  readonly kind = "jsonl";
  private accepted = new Set<string>();
  private ready: Promise<void>;

  constructor(private readonly path: string) {
    mkdirSync(dirname(this.path), { recursive: true });
    this.ready = this.load();
  }

  private async load() {
    let text: string;
    try {
      text = await readFile(this.path, "utf8");
    } catch {
      return; // no ledger yet — first acceptance creates it
    }
    for (const line of text.split("\n")) {
      const s = line.trim();
      if (!s) continue;
      try {
        const rec = JSON.parse(s) as TosAcceptance;
        if (rec.address && rec.version) this.accepted.add(key(rec.address, rec.version));
      } catch {
        // A single malformed line must not poison the whole index.
      }
    }
  }

  async recordAcceptance(a: TosAcceptance): Promise<void> {
    await this.ready;
    await appendFile(this.path, JSON.stringify(a) + "\n", "utf8");
    this.accepted.add(key(a.address, a.version));
  }

  async hasAccepted(address: string, version: string): Promise<boolean> {
    await this.ready;
    return this.accepted.has(key(address, version));
  }
}

// ---------------------------------------------------------------------------
// SQLite (node:sqlite) — preferred when the runtime provides it.
// ---------------------------------------------------------------------------

class SqliteTosStore implements TosStore {
  readonly kind = "sqlite";
  // node:sqlite is typed loosely here so the module type-checks on Node versions
  // whose @types/node predate the builtin; the factory only constructs this class
  // after confirming the module loads at runtime.
  private db: any;
  private insert: any;
  private select: any;

  constructor(DatabaseSync: any, path: string) {
    mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec(
      `CREATE TABLE IF NOT EXISTS tos_acceptances (
         id          INTEGER PRIMARY KEY AUTOINCREMENT,
         address     TEXT NOT NULL,
         version     TEXT NOT NULL,
         message     TEXT NOT NULL,
         signature   TEXT NOT NULL,
         timestamp   TEXT NOT NULL,
         recorded_at TEXT NOT NULL,
         terms_hash  TEXT,
         ip          TEXT,
         user_agent  TEXT
       );
       CREATE INDEX IF NOT EXISTS idx_tos_addr_ver
         ON tos_acceptances (address, version);`,
    );
    this.insert = this.db.prepare(
      `INSERT INTO tos_acceptances
         (address, version, message, signature, timestamp, recorded_at, terms_hash, ip, user_agent)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    );
    this.select = this.db.prepare(
      `SELECT 1 FROM tos_acceptances WHERE address = ? AND version = ? LIMIT 1`,
    );
  }

  async recordAcceptance(a: TosAcceptance): Promise<void> {
    this.insert.run(
      a.address.toLowerCase(),
      a.version,
      a.message,
      a.signature,
      a.timestamp,
      a.recordedAt,
      a.termsHash ?? null,
      a.ip ?? null,
      a.userAgent ?? null,
    );
  }

  async hasAccepted(address: string, version: string): Promise<boolean> {
    return this.select.get(address.toLowerCase(), version) !== undefined;
  }
}

// ---------------------------------------------------------------------------
// Factory: pick the backend and resolve the storage path.
// ---------------------------------------------------------------------------

const DEFAULT_DIR = resolve(process.cwd(), ".data");

export async function createTosStore(): Promise<TosStore> {
  const mode = (process.env.FERA_TOS_STORE ?? "auto").toLowerCase();

  if (mode !== "jsonl") {
    try {
      // Non-literal specifier: node:sqlite is a runtime-optional builtin (Node >= 22.5)
      // that older @types/node don't declare, so we resolve it dynamically at runtime
      // instead of having tsc try (and fail) to type-resolve the module.
      const sqliteSpecifier = "node:sqlite";
      const sqlite: any = await import(sqliteSpecifier);
      const DatabaseSync = sqlite.DatabaseSync;
      if (DatabaseSync) {
        const path =
          process.env.FERA_TOS_DB_PATH ?? resolve(DEFAULT_DIR, "tos.sqlite");
        return new SqliteTosStore(DatabaseSync, path);
      }
    } catch {
      if (mode === "sqlite") {
        // Explicitly asked for sqlite but the runtime can't provide it — fail loudly
        // rather than silently downgrading a deployment that expected a real DB.
        throw new Error(
          "FERA_TOS_STORE=sqlite but node:sqlite is unavailable (needs Node >= 22.5).",
        );
      }
      // auto: fall through to jsonl.
    }
  }

  const path =
    process.env.FERA_TOS_LEDGER_PATH ??
    resolve(DEFAULT_DIR, "tos-acceptances.jsonl");
  return new JsonlTosStore(path);
}
