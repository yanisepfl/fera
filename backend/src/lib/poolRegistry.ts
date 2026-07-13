// Resolves token metadata for a FERA poolId.
//
// F-8 (MASTER_SPEC v0.6 §6, BK-2 CLOSED at the interface level): `FeraHook` now emits
// `PoolRegistered(poolId, token0, token1, regime)` in beforeInitialize — token ADDRESSES and
// regime are event-sourced by the PoolRegistered handler. The event does NOT carry decimals/
// symbols, so this env registry remains the metadata fallback, in two forms:
//   FERA_POOL_TOKENS (JSON poolId -> {token0, token1, decimals, symbols})  — legacy, complete
//   FERA_TOKEN_META  (JSON tokenAddress -> {decimals, symbol})             — used with the event
// Production should additionally read decimals()/symbol() from the ERC-20s at registration
// (needs an RPC in the handler; deferred — see OPEN_DECISIONS.md D-BK-2 follow-up).

export interface PoolTokens {
  token0: `0x${string}`;
  token1: `0x${string}`;
  token0Decimals: number;
  token1Decimals: number;
  token0Symbol: string;
  token1Symbol: string;
}

const ZERO = "0x0000000000000000000000000000000000000000" as const;

function load(): Record<string, PoolTokens> {
  const raw = process.env.FERA_POOL_TOKENS;
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw) as Record<string, PoolTokens>;
    const out: Record<string, PoolTokens> = {};
    for (const [k, v] of Object.entries(parsed)) out[k.toLowerCase()] = v;
    return out;
  } catch {
    return {};
  }
}

const REGISTRY = load();

export function tokensFor(poolId: `0x${string}`): PoolTokens {
  return (
    REGISTRY[poolId.toLowerCase()] ?? {
      token0: ZERO,
      token1: ZERO,
      token0Decimals: 18,
      token1Decimals: 18,
      token0Symbol: "",
      token1Symbol: "",
    }
  );
}

// ---- per-token metadata (used by the F-8 PoolRegistered handler) --------------------------

export interface TokenMetaEntry {
  decimals: number;
  symbol: string;
}

function loadTokenMeta(): Record<string, TokenMetaEntry> {
  const raw = process.env.FERA_TOKEN_META;
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw) as Record<string, TokenMetaEntry>;
    const out: Record<string, TokenMetaEntry> = {};
    for (const [k, v] of Object.entries(parsed)) out[k.toLowerCase()] = v;
    return out;
  } catch {
    return {};
  }
}

const TOKEN_META = loadTokenMeta();

/** decimals/symbol for a token address — env-sourced fallback (default 18 / ""). */
export function tokenMetaFor(token: `0x${string}`): TokenMetaEntry {
  return TOKEN_META[token.toLowerCase()] ?? { decimals: 18, symbol: "" };
}
