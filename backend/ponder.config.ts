// Ponder config. Addresses/startBlocks come from ENV and are ultimately sourced from
// docs/CHAIN.md (Deployment 5) — DO NOT hardcode until CHAIN.md confirms them (MASTER_SPEC §3).
// Until then env defaults to the zero address so the project loads; a keeper/monitor will not
// find events against 0x0 (intended — forces wiring real addresses).
//
// Robinhood Chain: Arbitrum Orbit L2, ~100ms blocks. Use a paid Alchemy RPC in production.

import { createConfig } from "ponder";
import { http } from "viem";
import { FeraHookAbi } from "./abis/FeraHook";
import { FeraVaultAbi } from "./abis/FeraVault";
import { FeraTokenAbi } from "./abis/FeraToken";
import { EsFeraAbi } from "./abis/EsFera";
import { EmissionsControllerAbi } from "./abis/EmissionsController";
import { DistributorAbi } from "./abis/Distributor";
import { AnchorStakingAbi } from "./abis/AnchorStaking";
import { RevenueDistributorAbi } from "./abis/RevenueDistributor";
import { UniswapV3PoolAbi, UniswapV4PoolManagerAbi } from "./abis/competitors";

const ZERO = "0x0000000000000000000000000000000000000000" as const;
const RH = "robinhood";

const rpcUrl = process.env.PONDER_RPC_URL_RH ?? "http://127.0.0.1:8545";
const chainId = Number(process.env.PONDER_CHAIN_ID ?? 42161);

const addr = (name: string): `0x${string}` =>
  (process.env[name] ?? ZERO) as `0x${string}`;
const addrList = (name: string): `0x${string}`[] => {
  const v = process.env[name];
  if (!v) return [ZERO];
  return v.split(",").map((s) => s.trim() as `0x${string}`);
};
const startBlock = (name: string): number =>
  process.env[name] ? Number(process.env[name]) : 0;

export default createConfig({
  networks: {
    [RH]: {
      chainId,
      transport: http(rpcUrl),
      pollingInterval: Number(process.env.PONDER_POLL_MS ?? 200), // ~100ms blocks
    },
  },
  contracts: {
    FeraHook: {
      network: RH,
      abi: FeraHookAbi,
      address: addr("FERA_HOOK_ADDRESS"),
      startBlock: startBlock("FERA_START_BLOCK"),
    },
    FeraVault: {
      network: RH,
      abi: FeraVaultAbi,
      address: addr("FERA_VAULT_ADDRESS"),
      startBlock: startBlock("FERA_START_BLOCK"),
    },
    FeraToken: {
      network: RH,
      abi: FeraTokenAbi,
      address: addr("FERA_TOKEN_ADDRESS"),
      startBlock: startBlock("FERA_START_BLOCK"),
    },
    EsFera: {
      network: RH,
      abi: EsFeraAbi,
      address: addr("FERA_ESFERA_ADDRESS"),
      startBlock: startBlock("FERA_START_BLOCK"),
    },
    EmissionsController: {
      network: RH,
      abi: EmissionsControllerAbi,
      address: addr("FERA_EMISSIONS_ADDRESS"),
      startBlock: startBlock("FERA_START_BLOCK"),
    },
    Distributor: {
      network: RH,
      abi: DistributorAbi,
      address: addr("FERA_DISTRIBUTOR_ADDRESS"),
      startBlock: startBlock("FERA_START_BLOCK"),
    },
    AnchorStaking: {
      network: RH,
      abi: AnchorStakingAbi,
      address: addr("FERA_STAKING_ADDRESS"),
      startBlock: startBlock("FERA_START_BLOCK"),
    },
    RevenueDistributor: {
      network: RH,
      abi: RevenueDistributorAbi,
      address: addr("FERA_REVENUE_ADDRESS"),
      startBlock: startBlock("FERA_START_BLOCK"),
    },

    // ---- Competing vanilla pools on the SAME pairs (depth/fee comparison, §8 + V4) ----
    // Static address list of the vanilla v3 pools we benchmark against (from CHAIN.md).
    UniswapV3Competitor: {
      network: RH,
      abi: UniswapV3PoolAbi,
      address: addrList("RH_V3_COMPETITOR_POOLS"),
      startBlock: startBlock("RH_COMPETITOR_START_BLOCK"),
    },
    // Canonical v4 PoolManager singleton; competitor pools filtered by poolId in the handler.
    UniswapV4PoolManager: {
      network: RH,
      abi: UniswapV4PoolManagerAbi,
      address: addr("RH_V4_POOL_MANAGER"),
      startBlock: startBlock("RH_COMPETITOR_START_BLOCK"),
    },
  },
});
