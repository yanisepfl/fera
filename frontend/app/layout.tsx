import type { Metadata, Viewport } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import "./globals.css";
import { Providers } from "./providers";
import { TopNav } from "@/components/layout/TopNav";

export const metadata: Metadata = {
  title: {
    default: "FERA — Regime-aware liquidity",
    template: "%s · FERA",
  },
  description:
    "LP-first, regime-aware liquidity on Robinhood Chain. Earn more per dollar by monetizing every flow through fees that price toxicity.",
};

export const viewport: Viewport = {
  themeColor: "#0a0a0b",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  // Map Geist (self-hosted, no build-time fetch) onto the theme's font vars.
  const fontVars = {
    "--font-sans": GeistSans.style.fontFamily,
    "--font-mono": GeistMono.style.fontFamily,
  } as React.CSSProperties;

  return (
    <html
      lang="en"
      className={`${GeistSans.variable} ${GeistMono.variable} dark`}
      style={fontVars}
      suppressHydrationWarning
    >
      <body className="min-h-screen antialiased">
        <Providers>
          <TopNav />
          <main className="mx-auto w-full max-w-app px-4 py-6 md:px-6 md:py-10">
            {children}
          </main>
          <footer className="mx-auto max-w-app px-4 md:px-6 pb-10 pt-4">
            <div className="hr mb-4" />
            <p className="text-caption text-mute">
              FERA is LP-first infrastructure. Swaps are never gated and never
              charged a protocol fee (INV-2). Numbers shown are reproducible from
              on-chain data via Backend&apos;s published bundle (MASTER_SPEC §9).
            </p>
          </footer>
        </Providers>
      </body>
    </html>
  );
}
