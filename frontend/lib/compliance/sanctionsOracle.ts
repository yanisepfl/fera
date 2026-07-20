/**
 * Chainalysis free, keyless sanctions oracle — SERVER-ONLY.
 *
 * Do not import this from a client component; only lib/compliance/decision.ts calls it.
 *
 * Screens the CONNECTED WALLET ADDRESS (not the request IP — see config/geo.ts /
 * ipapi.ts / torList.ts for the IP-based checks) against Chainalysis's on-chain
 * sanctions-list contract. Verified live at this address on Ethereum mainnet (and
 * several other EVM chains); it is NOT deployed on Robinhood Chain (4663) itself, so
 * this reads it CROSS-CHAIN via an Ethereum-mainnet RPC. `isSanctioned(address)` is a
 * single plain `eth_call` — no API key, no rate limit beyond the RPC's own.
 *
 * Runs server-side only, invoked once per RWA deposit CONFIRM attempt (never on every
 * render/mount of a pool row — see lib/hooks/useRwaComplianceGate.ts and its call site
 * in components/earn/DepositDialog.tsx). A client-side-only sanctions check would be
 * trivially bypassed by a modified or malicious frontend talking to the vault directly,
 * so this must be enforced server-side, not merely in the UI.
 *
 * FAIL-CLOSED: unlike the IP-reputation checks (ipapi.is/Tor), an RPC failure here
 * BLOCKS the deposit rather than allowing it. Sanctions screening is a hard OFAC
 * compliance floor; letting a wallet through un-screened because an RPC call hiccuped
 * would defeat the entire point of running the check. The caller sees a clearly-labeled
 * "temporarily unavailable, please retry" reason — never a silent allow.
 */

if (typeof window !== "undefined") {
  throw new Error(
    "lib/compliance/sanctionsOracle.ts is server-only and must not be imported into a client bundle"
  );
}

import { createPublicClient, http, getAddress, isAddress } from "viem";
import { mainnet } from "viem/chains";

/** Chainalysis SanctionsList oracle — verified live on Ethereum mainnet. */
const ORACLE_ADDRESS = "0x40C57923924B5c5c5455c48D93317139ADDaC8fb" as const;

const ORACLE_ABI = [
  {
    type: "function",
    name: "isSanctioned",
    stateMutability: "view",
    inputs: [{ name: "addr", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

// Cross-chain read: this is deliberately NOT config/chains.ts (that file only ever
// registers Robinhood Chain mainnet/testnet for the wallet). Public free default;
// override with a dedicated mainnet RPC in production — see .env.example.
//
// NOTE (verified 2026-07-20): the research pass's suggested example,
// https://eth.llamarpc.com, was returning HTTP 521 (host down) when this was built and
// manually tested — confirmed with a plain curl, not a fluke of this code. Since this
// check FAILS CLOSED, shipping a dead default would silently block every RWA deposit.
// Using https://ethereum-rpc.publicnode.com instead (also free/keyless, verified live
// via `eth_chainId` -> 0x1 at the same time). Re-verify either endpoint's uptime before
// this gates real deposits, and set SANCTIONS_ORACLE_RPC_URL to a dedicated provider
// (Alchemy/Infura/etc.) for production reliability — free public RPCs are not an SLA.
const RPC_URL = process.env.SANCTIONS_ORACLE_RPC_URL || "https://ethereum-rpc.publicnode.com";

const client = createPublicClient({ chain: mainnet, transport: http(RPC_URL) });

export type SanctionsCheckStatus = "ok" | "flagged" | "error";

export interface SanctionsCheckResult {
  status: SanctionsCheckStatus;
  detail: string;
}

export async function checkWalletSanctioned(address: string): Promise<SanctionsCheckResult> {
  if (!address || !isAddress(address)) {
    // Not a real wallet to screen (e.g. no wallet connected yet) — nothing to flag, but
    // also nothing verified. Treated as "error" so the composed decision (decision.ts)
    // fails closed on it, same as an RPC failure: we never treat "couldn't check" as a
    // pass for a hard compliance floor.
    return { status: "error", detail: "no valid wallet address to screen" };
  }
  try {
    const sanctioned = await client.readContract({
      address: ORACLE_ADDRESS,
      abi: ORACLE_ABI,
      functionName: "isSanctioned",
      args: [getAddress(address)],
    });
    return sanctioned
      ? { status: "flagged", detail: "wallet address appears on Chainalysis's sanctions oracle" }
      : { status: "ok", detail: "not flagged by the sanctions oracle" };
  } catch (err) {
    // FAIL CLOSED (see file header) — the caller must treat "error" as block.
    return {
      status: "error",
      detail: `sanctions oracle unreachable (${err instanceof Error ? err.message : String(err)})`,
    };
  }
}
