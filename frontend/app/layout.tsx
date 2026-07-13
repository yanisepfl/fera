import type { Metadata, Viewport } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import "./globals.css";
import { Providers } from "./providers";

export const metadata: Metadata = {
  title: {
    default: "FERA - the liquidity layer that prices what others bleed",
    template: "%s · FERA",
  },
  description:
    "A Uniswap v4 hook on Robinhood Chain that charges toxic, mechanical, and weekend-arbitrage flow the fee it's actually worth - so the volatility that drains ordinary LPs pays FERA's LPs instead.",
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

  // Root layout is intentionally chrome-free: the marketing landing ("/") and the app
  // ("/app/*") each render their own header/footer. Providers (wagmi + RainbowKit +
  // React Query) wrap everything so the wallet is available on the landing CTA and in
  // the app alike.
  return (
    <html
      lang="en"
      className={`${GeistSans.variable} ${GeistMono.variable} dark`}
      style={fontVars}
      suppressHydrationWarning
    >
      <body className="min-h-screen antialiased">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
