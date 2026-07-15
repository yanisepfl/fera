import type { Metadata, Viewport } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import "./globals.css";
import { Providers } from "./providers";

const SITE_TITLE = "FERA - Earn like a market maker";
const SITE_DESCRIPTION =
  "Market makers earn a fee on every trade. FERA opens that seat to everyone: deposit into a vault that provides and auto-manages the liquidity, and earn the trading fees. On meme coins and stocks, built on Robinhood Chain.";

export const metadata: Metadata = {
  metadataBase: new URL("https://fera.fi"),
  title: {
    default: "FERA - Earn like a market maker, on meme coins and stocks",
    template: "%s · FERA",
  },
  description:
    "FERA democratizes market-making. Deposit into a vault that provides and actively manages liquidity in the pools you choose, and earn the trading fees - with an auto-adapting range and a dynamic fee that rises when it's volatile. Withdraw anytime. Built on Robinhood Chain.",
  openGraph: {
    type: "website",
    siteName: "FERA",
    url: "/",
    title: SITE_TITLE,
    description: SITE_DESCRIPTION,
  },
  twitter: {
    card: "summary_large_image",
    title: SITE_TITLE,
    description: SITE_DESCRIPTION,
  },
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
