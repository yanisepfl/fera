"use client";

import { useState } from "react";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { Button } from "@/components/ui/Button";
import { shortHex } from "@/lib/format";
import { ROBINHOOD_WALLET_DEEPLINK } from "@/lib/wagmi";
import { cn } from "@/lib/cn";

/**
 * Compact wallet connect. Lists injected + WalletConnect (when configured) + a
 * Robinhood-Wallet deep-link entry (beta — see lib/wagmi ROBINHOOD_WALLET_DEEPLINK).
 * Kept minimal on purpose (no RainbowKit) to match the calm, data-dense aesthetic.
 */
export function ConnectButton() {
  const { address, isConnected } = useAccount();
  const { connectors, connect, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const [open, setOpen] = useState(false);

  if (isConnected && address) {
    return (
      <Button variant="secondary" size="sm" onClick={() => disconnect()}>
        <span className="h-1.5 w-1.5 rounded-full bg-pos" />
        <span className="font-mono">{shortHex(address)}</span>
      </Button>
    );
  }

  return (
    <div className="relative">
      <Button size="sm" onClick={() => setOpen((v) => !v)} disabled={isPending}>
        {isPending ? "Connecting…" : "Connect"}
      </Button>
      {open ? (
        <>
          <div
            className="fixed inset-0 z-40"
            onClick={() => setOpen(false)}
            aria-hidden
          />
          <div className="absolute right-0 top-[calc(100%+8px)] z-50 w-64 rounded-lg border border-line-strong bg-raised p-1.5 shadow-pop">
            <div className="px-2.5 py-1.5 overline">Connect a wallet</div>
            {connectors.map((c) => (
              <WalletRow
                key={c.uid}
                label={c.name}
                onClick={() => {
                  connect({ connector: c });
                  setOpen(false);
                }}
              />
            ))}
            <WalletRow
              label="Robinhood Wallet"
              beta
              onClick={() => {
                // Deep-link path — falls back to WalletConnect until the scheme is confirmed.
                const wc = connectors.find((c) => c.id === "walletConnect");
                if (ROBINHOOD_WALLET_DEEPLINK.enabled && wc) {
                  connect({ connector: wc });
                } else if (wc) {
                  connect({ connector: wc });
                }
                setOpen(false);
              }}
            />
            {!connectors.some((c) => c.id === "walletConnect") ? (
              <p className="px-2.5 py-2 text-caption text-mute">
                Set{" "}
                <code className="font-mono text-dim">
                  NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID
                </code>{" "}
                for mobile + Robinhood Wallet.
              </p>
            ) : null}
          </div>
        </>
      ) : null}
    </div>
  );
}

function WalletRow({
  label,
  onClick,
  beta,
}: {
  label: string;
  onClick: () => void;
  beta?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      className={cn(
        "flex w-full items-center justify-between gap-2 rounded-md px-2.5 py-2",
        "text-body-sm text-dim hover:bg-hover hover:text-text transition-colors"
      )}
    >
      <span className="flex items-center gap-2">
        <span className="grid h-5 w-5 place-items-center rounded bg-surface text-[10px] font-semibold text-mute">
          {label.slice(0, 1)}
        </span>
        {label}
      </span>
      {beta ? (
        <span className="text-micro uppercase tracking-wide text-accent">beta</span>
      ) : null}
    </button>
  );
}
