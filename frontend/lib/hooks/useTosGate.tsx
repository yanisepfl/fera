"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
} from "react";
import { useAccount, useSignMessage, useDisconnect } from "wagmi";
import {
  TOS_VERSION,
  buildTosMessage,
  computeTermsHash,
  makeNonce,
} from "@/lib/tos";
import { getTosStatus, postTosAcceptance } from "@/lib/tosApi";
import { TosGate } from "@/components/legal/TosGate";

/**
 * ToS acceptance gate.
 *
 * Flow: an UNCONNECTED user browses read-only (actionable CTAs already prompt connect).
 * On the FIRST connect we check acceptance of the current ToS version; if not accepted we
 * raise a blocking, non-dismissible gate that covers the app until the user either signs
 * the acceptance (personal_sign → recorded server-side) or disconnects. Because the gate
 * is a full-screen overlay above the app, no deposit/withdraw/stake/claim/vote control
 * underneath is reachable until acceptance — which is exactly the requirement.
 */

type Phase = "idle" | "checking" | "required" | "accepted";

interface TosGateValue {
  phase: Phase;
  /** connected AND accepted — safe to perform on-chain actions. */
  canAct: boolean;
  /** connected AND acceptance still required. */
  needsAcceptance: boolean;
  signing: boolean;
  error: string | null;
  accept: () => Promise<void>;
  disconnect: () => void;
  version: string;
}

const Ctx = createContext<TosGateValue | null>(null);

/** Read the gate state (e.g. to defensively disable an action while unsigned). */
export function useTosGate(): TosGateValue {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useTosGate must be used within <TosGateProvider>");
  return ctx;
}

export function TosGateProvider({ children }: { children: React.ReactNode }) {
  const { address, isConnected } = useAccount();
  const { signMessageAsync } = useSignMessage();
  const { disconnect } = useDisconnect();

  const [phase, setPhase] = useState<Phase>("idle");
  const [signing, setSigning] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mounted, setMounted] = useState(false);

  useEffect(() => setMounted(true), []);

  // Check acceptance whenever the connected address changes.
  useEffect(() => {
    if (!mounted) return;
    if (!isConnected || !address) {
      setPhase("idle");
      setError(null);
      return;
    }
    let cancelled = false;
    setPhase("checking");
    getTosStatus(address, TOS_VERSION)
      .then((s) => {
        if (!cancelled) setPhase(s.accepted ? "accepted" : "required");
      })
      .catch(() => {
        if (!cancelled) setPhase("required"); // fail closed
      });
    return () => {
      cancelled = true;
    };
  }, [mounted, isConnected, address]);

  const accept = useCallback(async () => {
    if (!address) return;
    setSigning(true);
    setError(null);
    try {
      const nonce = makeNonce();
      const issuedAt = new Date().toISOString();
      const termsHash = await computeTermsHash();
      const message = buildTosMessage({ address, nonce, issuedAt, termsHash });
      const signature = await signMessageAsync({ message });
      await postTosAcceptance({
        address,
        version: TOS_VERSION,
        message,
        signature,
        timestamp: issuedAt,
        termsHash,
      });
      setPhase("accepted");
    } catch (e: unknown) {
      const err = e as { shortMessage?: string; message?: string };
      // User rejecting the signature in the wallet is expected — keep the gate up quietly.
      const msg = err?.shortMessage || err?.message || "Could not complete acceptance.";
      setError(/rejected|denied|user cancel/i.test(msg) ? null : msg);
    } finally {
      setSigning(false);
    }
  }, [address, signMessageAsync]);

  const value: TosGateValue = {
    phase,
    canAct: phase === "accepted",
    needsAcceptance: isConnected && phase === "required",
    signing,
    error,
    accept,
    disconnect: () => disconnect(),
    version: TOS_VERSION,
  };

  return (
    <Ctx.Provider value={value}>
      {children}
      {mounted && isConnected && phase === "required" ? (
        <TosGate
          version={TOS_VERSION}
          signing={signing}
          error={error}
          onAccept={accept}
          onDisconnect={() => disconnect()}
        />
      ) : null}
    </Ctx.Provider>
  );
}
