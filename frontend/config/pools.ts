/**
 * FERA live pools — Robinhood Chain (4663). Seeded 2026-07-17/18 from POOL_CREATOR.
 * This is the canonical on-chain registry the UI + tracker read from.
 *
 * Each pool has TWO tranches on-chain (0 = "Steady"/Anchor, 1 = "Active"/Core — verified
 * against FeraConstants.sol's TIER_STEADY=0/TIER_ACTIVE=1; see lib/riskClass.ts's
 * RISK_CLASS_META for the canonical label↔tranche mapping, the single source of truth —
 * don't infer it from prose elsewhere). `createBaseLimitPool` initializes BOTH tranches'
 * FeraShare clones at pool creation, but only tranche 0 has real deposits so far.
 * `share` below is the tranche-0 clone (confirmed for every pool here); tranche 1's
 * clone address is deliberately NOT hardcoded per pool — it's resolved live via
 * FeraVault.shareToken(poolId, 1) (lib/hooks/useVaultTx.ts#useShareAddress) so every
 * pool works correctly without needing each tranche-1 address confirmed by hand.
 * quoteIsToken0 = true iff the quote (wWETH) sorts BELOW the memecoin address.
 */
export const VAULT = "0xa8cF82797ecBC8C5cD5F83D60e189dbDc88D959a" as const;
export const HOOK = "0x96CE193F25db9b75743332bB7C94e545f1a225C3" as const;
export const WWETH = "0x0bd7d308f8e1639fab988df18a8011f41eacad73" as const;
export const USDG = "0x5fc5360d0400a0fd4f2af552add042d716f1d168" as const;

export interface LivePool {
  symbol: string;
  poolId: `0x${string}`;
  share: `0x${string}`; // tranche 0 ("Steady"/Anchor) FeraShare — see header comment
  memecoin: `0x${string}`;
  memecoinDecimals: number;
  quote: `0x${string}`;
  quoteSymbol: "wWETH" | "USDG";
  quoteDecimals: number;
  quoteIsToken0: boolean;
}

/** Registry lookup by v4 PoolId (case-insensitive). undefined = not a live on-chain pool. */
export function livePoolById(poolId: string | undefined): LivePool | undefined {
  if (!poolId) return undefined;
  const id = poolId.toLowerCase();
  return LIVE_POOLS.find((p) => p.poolId.toLowerCase() === id);
}

/**
 * The pool's tokens in TRUE on-chain (currency0/currency1) order — the order
 * `FeraVault.deposit(id, t, amount0, amount1, …)` expects amounts in.
 */
export function poolTokenPair(p: LivePool): {
  token0: { address: `0x${string}`; symbol: string; decimals: number };
  token1: { address: `0x${string}`; symbol: string; decimals: number };
} {
  const meme = { address: p.memecoin, symbol: p.symbol, decimals: p.memecoinDecimals };
  const quote = { address: p.quote, symbol: p.quoteSymbol, decimals: p.quoteDecimals };
  return p.quoteIsToken0 ? { token0: quote, token1: meme } : { token0: meme, token1: quote };
}

export const LIVE_POOLS: LivePool[] = [
  {
    symbol: "TENDIES",
    poolId: "0x781f4bd64678be81a559f58bb124c570fb86abc04831f1c41212984340df9a12",
    share: "0x19E713E0CB2a385CE45cE84851ED9063c87d0E18",
    memecoin: "0x45242320dbb855eea8fd36804c6487e10e97fcf9",
    memecoinDecimals: 18,
    quote: WWETH, quoteSymbol: "wWETH", quoteDecimals: 18, quoteIsToken0: true,
  },
  {
    symbol: "VIRTUAL",
    poolId: "0x4412b3443d6f50184af006e8e0fa2573ef0b7ef7ddb675738971311a27236ef7",
    share: "0xBD75122950C8396f560090eC1819bEdc19F42c64",
    memecoin: "0xc6911796042b15d7fa4f6cde69e245ddcd3d9c31",
    memecoinDecimals: 18,
    quote: WWETH, quoteSymbol: "wWETH", quoteDecimals: 18, quoteIsToken0: true,
  },
  {
    symbol: "GME",
    poolId: "0x848c3b7e44feed741b097eecba7846dd96414e8b1fc21488c71c8b9bcb115cb5",
    share: "0x1688cE036b304996225D7a299D8Ff960ccE51fD4",
    memecoin: "0x7e86381a763f0ecca2bdf27c54eac403ddd48123",
    memecoinDecimals: 18,
    quote: WWETH, quoteSymbol: "wWETH", quoteDecimals: 18, quoteIsToken0: true,
  },
  {
    symbol: "WALLET",
    poolId: "0x877c04e865fffdfb450a86e5d1c3e5892ea56d5e33e3d56733249330a5b234b3",
    share: "0x6C75B849D281361eD43B51c2f314bfD23ec8B42C",
    memecoin: "0x0339f5459fc690ac85f1782e15782a151b4a9e1b",
    memecoinDecimals: 18,
    quote: WWETH, quoteSymbol: "wWETH", quoteDecimals: 18, quoteIsToken0: false,
  },
  {
    symbol: "PONS",
    poolId: "0x4f382e3ceda365063d6824280583f2c485fe4f5c21178c39901c45f11a47e44d",
    share: "0x7a5D09b03509417431f7D18b24A8858D4F8E0785",
    memecoin: "0x39dbed3a2bd333467115de45665cc57f813c4571",
    memecoinDecimals: 18,
    quote: WWETH, quoteSymbol: "wWETH", quoteDecimals: 18, quoteIsToken0: true,
  },
];
