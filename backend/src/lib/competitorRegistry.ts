// Metadata for competing vanilla Uniswap v3/v4 pools we benchmark FERA pools against
// (MASTER_SPEC §8 /pools/:poolId/depth; verification V4 "LPs strictly beat vanilla v3/v4").
//
// Like poolRegistry, the on-chain Swap/Mint/Burn events for a v3 pool do NOT carry token
// addresses/decimals, and v4 PoolManager events carry only a poolId. So metadata (dex, tokens,
// decimals, fee tier, canonical pairKey) is supplied via an env registry until the pool-init
// reads are wired. `pairKey` is the canonical `${min}:${max}` used to JOIN against FERA pools.
// TODO(deploy): populate from CHAIN.md competitor list + on-chain token()/decimals() reads.

export interface CompetitorMeta {
  dex: "univ3" | "univ4";
  token0: `0x${string}`;
  token1: `0x${string}`;
  token0Decimals: number;
  token1Decimals: number;
  feeTier: number; // static v3 fee (pips); last-observed for v4
  pairKey: string; // `${min(token0,token1)}:${max}` (lowercase)
}

function canonicalPairKey(a: string, b: string): string {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  return x < y ? `${x}:${y}` : `${y}:${x}`;
}

function load(): Record<string, CompetitorMeta> {
  const raw = process.env.COMPETITOR_POOL_META;
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw) as Record<string, Omit<CompetitorMeta, "pairKey"> & { pairKey?: string }>;
    const out: Record<string, CompetitorMeta> = {};
    for (const [id, m] of Object.entries(parsed)) {
      out[id.toLowerCase()] = { ...m, pairKey: m.pairKey ?? canonicalPairKey(m.token0, m.token1) };
    }
    return out;
  } catch {
    return {};
  }
}

const REGISTRY = load();

export function competitorMeta(id: `0x${string}`): CompetitorMeta | null {
  return REGISTRY[id.toLowerCase()] ?? null;
}

export { canonicalPairKey };
