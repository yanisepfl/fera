"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { usePublicClient } from "wagmi";
import { BaseError, encodeFunctionData } from "viem";
import { activeChain } from "@/config/chains";
import { VAULT, livePoolById } from "@/config/pools";
import { feraVaultAbi } from "@/lib/abi/feraVault";

/**
 * Proactive "can I deposit right now?" probe for a live registry pool.
 *
 * The vault runs an anti-manipulation price check at the TOP of `deposit()`, BEFORE it
 * pulls any tokens. During sharp memecoin moves that check reverts with the custom error
 * `TwapGateExceeded()` — briefly refusing new deposits so nobody enters at a manipulated
 * price. Because the check runs first, a read-only `eth_call` of `deposit()` with dummy
 * dust reveals the gate's state without spending gas or moving tokens:
 *
 *   • reverts with the TwapGateExceeded selector (0x5f35d826)  → gate CLOSED (open = false)
 *   • reverts with ANYTHING else (e.g. the ERC-20 pull failing on the empty probe
 *     address) or simulates clean                              → gate OPEN  (open = true)
 *   • transport / RPC failure — no deterministic answer        → UNKNOWN    (open = undefined)
 *
 * The consumer treats `undefined` as "let them try" (no banner, button enabled); the
 * post-submit error mapping in useVaultTx is the backstop if a deposit still races a close.
 *
 * Only pools in config/pools.ts are probed — fixture/mock pools return a permanently
 * unknown gate and are never touched.
 */

const CHAIN_ID = activeChain.id;

/** How often to re-probe while mounted — a closed gate reopens on its own as vol calms. */
const RECHECK_MS = 20_000;

/**
 * 4-byte selector of FeraVault's `TwapGateExceeded()` custom error
 * (`keccak256("TwapGateExceeded()")[:4]`). Verified against the deployed ABI.
 */
export const TWAP_GATE_SELECTOR = "0x5f35d826";

export interface DepositGate {
  /** true = deposits accepted · false = paused for a moment · undefined = unknown. */
  open: boolean | undefined;
  /** a probe round-trip is currently in flight. */
  checking: boolean;
  /** re-run the probe immediately (e.g. a manual "check again"). */
  recheck: () => void;
}

/** Pull the raw revert-data hex out of a viem call error, if the node returned any. */
function revertData(err: unknown): string | undefined {
  if (!(err instanceof BaseError)) return undefined;
  let hex: string | undefined;
  err.walk((e) => {
    const d = (e as { data?: unknown }).data;
    if (typeof d === "string" && d.startsWith("0x")) {
      hex = d;
      return true;
    }
    // viem's RawContractError can wrap the data as { data: '0x..' }.
    if (d && typeof d === "object") {
      const inner = (d as { data?: unknown }).data;
      if (typeof inner === "string" && inner.startsWith("0x")) {
        hex = inner;
        return true;
      }
    }
    return false;
  });
  return hex;
}

/** Flatten an error to searchable text — some RPCs echo the selector only in the message. */
function errorText(err: unknown): string {
  if (err instanceof BaseError) {
    return [err.shortMessage, err.message, ...(err.metaMessages ?? [])].join(" ");
  }
  return err instanceof Error ? err.message : String(err);
}

/**
 * Read a probe outcome from a thrown `eth_call` error:
 *   false     → CLOSED  (TwapGateExceeded selector present — the gate fired first)
 *   true      → OPEN    (the node executed the call and reverted for some OTHER reason)
 *   undefined → UNKNOWN (transport/RPC failure — no on-chain answer to trust)
 */
function classifyProbeError(err: unknown): boolean | undefined {
  const data = revertData(err);
  if (data) {
    return data.toLowerCase().startsWith(TWAP_GATE_SELECTOR) ? false : true;
  }
  // No structured revert data — the selector may still be echoed in the text.
  if (errorText(err).toLowerCase().includes(TWAP_GATE_SELECTOR)) return false;
  // Couldn't extract an on-chain answer (rate-limit, timeout, RPC down, …).
  return undefined;
}

export function useDepositGate(poolId: string | undefined): DepositGate {
  const client = usePublicClient({ chainId: CHAIN_ID });
  const live = useMemo(() => livePoolById(poolId), [poolId]);
  const [open, setOpen] = useState<boolean | undefined>(undefined);
  const [checking, setChecking] = useState(false);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const probe = useCallback(async () => {
    // Fixture/mock pools have no on-chain gate — never probe them.
    if (!live || !client) return;
    setChecking(true);
    try {
      // Static, gas-free eth_call from the empty probe address. Dust amounts (1 wei each)
      // with minShares=0 on tranche 0 (the seeded tranche): the price gate reverts FIRST
      // if spot is out of band; otherwise execution falls through to the token pull, which
      // reverts on the probe address — no tokens ever move either way.
      const data = encodeFunctionData({
        abi: feraVaultAbi,
        functionName: "deposit",
        args: [live.poolId, 0, 1n, 1n, 0n],
      });
      await client.call({ to: VAULT, data });
      // Simulated clean all the way through → gate is open.
      if (mounted.current) setOpen(true);
    } catch (err) {
      const result = classifyProbeError(err);
      // Keep the last known state on transient UNKNOWN failures so the UI never flickers;
      // the next tick refreshes it. (First-ever unknown just stays undefined = "let them try".)
      if (mounted.current && result !== undefined) setOpen(result);
    } finally {
      if (mounted.current) setChecking(false);
    }
  }, [live, client]);

  useEffect(() => {
    if (!live) {
      setOpen(undefined);
      return;
    }
    void probe();
    const id = setInterval(() => void probe(), RECHECK_MS);
    return () => clearInterval(id);
  }, [live, probe]);

  return { open: live ? open : undefined, checking, recheck: probe };
}
