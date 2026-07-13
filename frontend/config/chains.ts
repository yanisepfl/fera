import { defineChain } from "viem";

/**
 * Robinhood Chain — permissionless Arbitrum Orbit L2 (SHARED_CONTEXT).
 * ~100ms blocks, EVM, Alchemy RPC, Chainlink oracle infra, 90-day gas-fee holiday.
 *
 * Concrete chainId / RPC / explorer are confirmed by Deployment (5) in docs/CHAIN.md.
 * Values here are env-overridable placeholders — DO NOT hardcode production values
 * until CHAIN.md confirms them (mirrors the same rule Contracts follow, MASTER_SPEC §3).
 */
const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 0) || 98765; // placeholder
const RPC_URL =
  process.env.NEXT_PUBLIC_RPC_URL || "https://rpc.robinhood-chain.example";
const EXPLORER_URL =
  process.env.NEXT_PUBLIC_EXPLORER_URL || "https://explorer.robinhood-chain.example";

export const robinhoodChain = defineChain({
  id: CHAIN_ID,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [RPC_URL] },
  },
  blockExplorers: {
    default: { name: "RH Explorer", url: EXPLORER_URL },
  },
  testnet: false,
  // ~100ms blocks — poll fast when live.
  contracts: {},
});

export const EXPLORER_TX = (hash: string) => `${EXPLORER_URL}/tx/${hash}`;
export const EXPLORER_ADDR = (addr: string) => `${EXPLORER_URL}/address/${addr}`;
