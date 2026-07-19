import type { Metadata, Viewport } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import "./globals.css";
import { Providers } from "./providers";

const SITE_TITLE = "FERA - Put your meme coins to work";
const SITE_DESCRIPTION =
  "Meme coins never sit still. Deposit the coins you hold into a FERA vault and earn the trading fees from all their volatility, automatically. Actively managed, non-custodial, on Robinhood Chain. Tokenized stocks coming soon.";

export const metadata: Metadata = {
  metadataBase: new URL("https://fera.fi"),
  title: {
    default: "FERA - Put your meme coins to work, on Robinhood Chain",
    template: "%s · FERA",
  },
  description:
    "Deposit the meme coins you already hold into a vault that provides and actively manages the liquidity, and earn the fees from every trade, climbing when the market runs hot. On-chain and verifiable. Tokenized stocks coming soon. Built on Robinhood Chain.",
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
  themeColor: "#080b0a",
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
