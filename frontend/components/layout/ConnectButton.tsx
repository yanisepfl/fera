"use client";

import { ConnectButton as RainbowConnectButton } from "@rainbow-me/rainbowkit";
import { Button } from "@/components/ui/Button";
import { shortHex } from "@/lib/format";

/**
 * Wallet connect — RainbowKit's modal (family-standard WalletConnect UX) triggered by a
 * button rendered in the FERA design system, so the connect affordance stays calm and
 * in-aesthetic (DESIGN.md) instead of RainbowKit's stock chrome. Same export name as
 * before, so TopNav and the landing import it unchanged.
 */
export function ConnectButton() {
  return (
    <RainbowConnectButton.Custom>
      {({
        account,
        chain,
        openAccountModal,
        openChainModal,
        openConnectModal,
        authenticationStatus,
        mounted,
      }) => {
        const ready = mounted && authenticationStatus !== "loading";
        const connected =
          ready &&
          account &&
          chain &&
          (!authenticationStatus || authenticationStatus === "authenticated");

        return (
          <div
            aria-hidden={!ready}
            className={ready ? undefined : "pointer-events-none opacity-0"}
          >
            {!connected || !account || !chain ? (
              <Button size="sm" onClick={openConnectModal}>
                Connect
              </Button>
            ) : chain.unsupported ? (
              <Button variant="danger" size="sm" onClick={openChainModal}>
                Wrong network
              </Button>
            ) : (
              <Button variant="secondary" size="sm" onClick={openAccountModal}>
                <span className="h-1.5 w-1.5 rounded-full bg-pos" />
                <span className="font-mono">{shortHex(account.address)}</span>
              </Button>
            )}
          </div>
        );
      }}
    </RainbowConnectButton.Custom>
  );
}
