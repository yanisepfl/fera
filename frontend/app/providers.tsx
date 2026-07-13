"use client";

import { useEffect, useState } from "react";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { wagmiConfig } from "@/lib/wagmi";

/**
 * App-wide client providers: wagmi (wallets) + React Query (data + wagmi internals).
 * MSW is started lazily only when NEXT_PUBLIC_USE_MSW=1 (otherwise lib/api.ts serves
 * fixtures directly with no worker).
 */
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
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
