import { defineChain } from "viem";

/**
 * Robinhood Chain - permissionless Arbitrum Orbit L2 (SHARED_CONTEXT; docs/CHAIN.md).
 * ~100ms soft blocks, EVM-equivalent, native gas token = ETH, Blockscout explorer.
 *
 * Chain IDs are FIXED constants (mainnet 4663 / testnet 46630 - VERIFIED in
 * docs/CHAIN.md §0/§1); env vars only override RPC/explorer endpoints (e.g. to point at
 * an Alchemy/QuickNode RPC - the public RPC is rate-limited) and pick which network is
 * "active". This keeps both chains in the wagmi config with distinct ids.
 */

// --- Mainnet (chain id 4663) --------------------------------------------------
export const robinhoodChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: {
      http: [
        process.env.NEXT_PUBLIC_RPC_URL ||
          "https://rpc.mainnet.chain.robinhood.com",
      ],
    },
  },
  blockExplorers: {
    default: {
      name: "Blockscout",
      url:
        process.env.NEXT_PUBLIC_EXPLORER_URL ||
        "https://robinhoodchain.blockscout.com",
    },
  },
  testnet: false,
  // ~100ms soft blocks - poll fast when live.
  // Canonical Multicall3 IS deployed on 4663 (verified via eth_getCode 2026-07-18) —
  // registering it lets wagmi/viem batch the useReadContracts fans into one aggregate3 call.
  contracts: {
    multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" },
  },
});

// --- Testnet (chain id 46630) -------------------------------------------------
export const robinhoodTestnet = defineChain({
  id: 46630,
  name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: {
      http: [
        process.env.NEXT_PUBLIC_TESTNET_RPC_URL ||
          "https://rpc.testnet.chain.robinhood.com",
      ],
    },
  },
  blockExplorers: {
    default: {
      name: "Blockscout",
      url:
        process.env.NEXT_PUBLIC_TESTNET_EXPLORER_URL ||
        "https://explorer.testnet.chain.robinhood.com",
    },
  },
  testnet: true,
  contracts: {},
});

/**
 * The network the app treats as "home" (deposits target it, explorer links resolve to
 * it). Defaults to mainnet; set NEXT_PUBLIC_CHAIN_ID=46630 to make the testnet active
 * (e.g. for the §14 2-week soak). Both chains are always registered in the wallet.
 */
const ACTIVE_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 0) || 4663;
export const activeChain =
  ACTIVE_ID === 46630 ? robinhoodTestnet : robinhoodChain;

const ACTIVE_EXPLORER = activeChain.blockExplorers.default.url;
export const EXPLORER_TX = (hash: string) => `${ACTIVE_EXPLORER}/tx/${hash}`;
export const EXPLORER_ADDR = (addr: string) => `${ACTIVE_EXPLORER}/address/${addr}`;
