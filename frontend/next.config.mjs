/** @type {import('next').NextConfig} */

// ---------------------------------------------------------------------------
// Content-Security-Policy — connect-src allow-list.
//
// A wallet dApp must let the browser reach: the WalletConnect relay + explorer,
// the configured chain RPC(s), the FERA API origin, and GeckoTerminal (live
// market data). NEXT_PUBLIC_* are inlined at BUILD time, so we read them here to
// keep the CSP in lock-step with whatever endpoints the app is actually built for.
// Anything not listed is blocked — that is the point.
// ---------------------------------------------------------------------------

/** Scheme+host origin of a URL, or null if unusable (so a blank env var is a no-op). */
function origin(url) {
  try {
    return new URL(url).origin;
  } catch {
    return null;
  }
}

const ENV_ORIGINS = [
  origin(process.env.NEXT_PUBLIC_API_URL),
  origin(process.env.NEXT_PUBLIC_RPC_URL),
  origin(process.env.NEXT_PUBLIC_TESTNET_RPC_URL),
  origin(process.env.NEXT_PUBLIC_EXPLORER_URL),
  origin(process.env.NEXT_PUBLIC_TESTNET_EXPLORER_URL),
].filter(Boolean);

// Wallet + market infrastructure the connectors from RainbowKit's getDefaultConfig
// (WalletConnect/Reown, Coinbase, MetaMask SDK) and the live market feed reach out to.
const WALLET_MARKET_CONNECT = [
  "https://api.geckoterminal.com",
  "wss://relay.walletconnect.com",
  "https://*.walletconnect.com",
  "wss://*.walletconnect.com",
  "https://*.walletconnect.org",
  "wss://*.walletconnect.org",
  "https://*.reown.com",
  "wss://*.reown.com",
  // Reown AppKit / WalletConnect config + analytics (formerly Web3Modal).
  "https://*.web3modal.org",
  "https://*.web3modal.com",
  "https://*.coinbase.com",
  "wss://*.coinbase.com",
  // Robinhood Chain infra (RPC + Blockscout) — subdomains of the chain host.
  "https://*.chain.robinhood.com",
  "https://*.robinhood.com",
];

const FRAME_SRC = [
  "'self'",
  "https://*.walletconnect.com",
  "https://*.walletconnect.org",
  "https://*.reown.com",
  "https://verify.walletconnect.com",
  "https://verify.walletconnect.org",
];

// NOTE (nonce hardening — TODO): this ships a FUNCTIONAL CSP, not a maximally-strict
// one. Next 14 injects inline bootstrap <script> and inline styles, and RainbowKit
// injects inline styles, so we allow 'unsafe-inline' for script/style. 'unsafe-eval'
// is intentionally OMITTED (production `next start` does not need it and the wallet
// stack works without it — verified with a served headless check). The strict-CSP
// upgrade is a per-request nonce (middleware-generated) applied to script-src +
// style-src, removing 'unsafe-inline'. Deferred so we never ship a CSP that breaks
// the app. `upgrade-insecure-requests` is also omitted so a local http:// API/RPC
// keeps working in dev; HSTS enforces https on the deployed origin instead.
const CSP = [
  "default-src 'self'",
  "base-uri 'self'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "form-action 'self'",
  "manifest-src 'self'",
  "worker-src 'self' blob:",
  "img-src 'self' data: blob: https:",
  "font-src 'self' data:",
  "style-src 'self' 'unsafe-inline'",
  // `next dev` serves eval-source-map chunks, so DEV (and only dev) additionally needs
  // 'unsafe-eval' or the app never hydrates. Production keeps the strict form.
  process.env.NODE_ENV === "development"
    ? "script-src 'self' 'unsafe-inline' 'unsafe-eval'"
    : "script-src 'self' 'unsafe-inline'",
  `frame-src ${FRAME_SRC.join(" ")}`,
  `connect-src ${["'self'", ...ENV_ORIGINS, ...WALLET_MARKET_CONNECT].join(" ")}`,
].join("; ");

// Applied to every route. Clickjacking (X-Frame-Options + frame-ancestors), MIME
// sniffing, referrer leakage, and powerful-feature access are all closed by default;
// HSTS pins https for 2y on the deployed origin.
const SECURITY_HEADERS = [
  { key: "Content-Security-Policy", value: CSP },
  {
    key: "Strict-Transport-Security",
    value: "max-age=63072000; includeSubDomains; preload",
  },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  {
    key: "Permissions-Policy",
    value: "camera=(), microphone=(), geolocation=(), interest-cohort=()",
  },
  { key: "X-DNS-Prefetch-Control", value: "off" },
];

const nextConfig = {
  reactStrictMode: true,
  // ESLint is run separately; don't fail the production build on lint rules.
  eslint: { ignoreDuringBuilds: true },
  async headers() {
    return [{ source: "/:path*", headers: SECURITY_HEADERS }];
  },
  // wagmi/walletconnect/metamask pull optional native deps that must be treated as
  // external / stubbed in web bundling. This keeps `next build` clean.
  webpack: (config) => {
    config.externals.push('pino-pretty', 'lokijs', 'encoding');
    config.resolve = config.resolve || {};
    config.resolve.alias = {
      ...(config.resolve.alias || {}),
      // RN-only optional dep pulled by @metamask/sdk; stub it in the web build.
      '@react-native-async-storage/async-storage': false,
    };
    return config;
  },
};

export default nextConfig;
