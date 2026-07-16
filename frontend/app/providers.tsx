"use client";

import { useEffect, useState } from "react";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  RainbowKitProvider,
  darkTheme,
  type Theme,
} from "@rainbow-me/rainbowkit";
import "@rainbow-me/rainbowkit/styles.css";
import { wagmiConfig } from "@/lib/wagmi";

/**
 * App-wide client providers: wagmi (wallets) + React Query + RainbowKit (the wallet
 * modal). MSW is started lazily only when NEXT_PUBLIC_USE_MSW=1 (otherwise lib/api.ts
 * serves fixtures directly with no worker).
 *
 * RainbowKit is themed onto the FERA dark surface (DESIGN.md tokens) so the modal
 * reads as part of the app, not a bolted-on default. Wallet connect is an ACTION,
 * so it carries the green action accent (--accent2), not the gold brand accent.
 * `modalSize="compact"` keeps the calm, data-dense register.
 */
const feraWalletTheme: Theme = darkTheme({
  accentColor: "#2ecf88", // --accent2 (action green)
  accentColorForeground: "#04140c", // --on-accent2
  borderRadius: "medium",
  fontStack: "system",
  overlayBlur: "small",
});
// Nudge the modal chrome onto the ink scale (near-black surfaces + hairline borders).
feraWalletTheme.colors.modalBackground = "#121215"; // --ink-875 (card)
feraWalletTheme.colors.modalBorder = "#23232a"; // --line
feraWalletTheme.colors.profileForeground = "#161619"; // --ink-850 (elevated)
feraWalletTheme.colors.connectButtonBackground = "#1b1b1f"; // --ink-800 (surface)
feraWalletTheme.colors.menuItemBackground = "#161619"; // --ink-850

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 10_000,
            retry: 1,
            refetchOnWindowFocus: false,
          },
        },
      })
  );

  useEffect(() => {
    if (process.env.NEXT_PUBLIC_USE_MSW === "1") {
      import("@/mocks/browser").then(({ startMocks }) => startMocks());
    }
  }, []);

  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={feraWalletTheme} modalSize="compact">
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
