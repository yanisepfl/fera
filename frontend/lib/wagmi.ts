import { http } from "wagmi";
import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { robinhoodChain, robinhoodTestnet } from "@/config/chains";

/**
 * wagmi + RainbowKit config.
 *
 * Wallet UX is RainbowKit (the alphix-family idiom is a WalletConnect-based modal - 
 * alphix's own frontend uses Reown AppKit; we use RainbowKit, the family standard, so
 * the modal layers *additively* on top of the existing wagmi v2 config, degrades to
 * injected-only with zero env, and themes cleanly to the Fera-Green dark surface. See
 * app/providers.tsx for the theme wiring and components/layout/ConnectButton.tsx for
 * the in-aesthetic trigger).
 *
 * getDefaultConfig bundles the curated connector set (injected/MetaMask, WalletConnect,
 * Coinbase, Rainbow, …). Injected wallets - incl. the Robinhood Wallet in-app browser
 * if it injects window.ethereum - work with NO env. WalletConnect (mobile + QR) needs
 * NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID; until it is set we pass a non-empty placeholder
 * so config creation + `next build`/SSR never throw (the WC client is created lazily on
 * connect, not at module load).
 *
 * ssr:true → getDefaultConfig uses cookieStorage, so RSC/`next build` never touch a
 * wallet at render time.
 */
const wcProjectId =
  process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ||
  "FERA_SET_NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID";

export const wagmiConfig = getDefaultConfig({
  appName: "FERA",
  appDescription: "Regime-aware liquidity on Robinhood Chain",
  appUrl: "https://fera.fi",
  appIcon: "https://fera.fi/icon.png",
  projectId: wcProjectId,
  chains: [robinhoodChain, robinhoodTestnet],
  transports: {
    [robinhoodChain.id]: http(),
    [robinhoodTestnet.id]: http(),
  },
  ssr: true,
});

/**
 * ROBINHOOD WALLET DEEP-LINK - investigation note (still open; kept for Deployment/GTM).
 * -------------------------------------------------------------------------------------
 * Robinhood Wallet exposes no confirmed public WalletConnect allow-list entry or
 * documented deep-link scheme yet. Three viable paths, in order of preference:
 *   1. WalletConnect v2 - if RH Wallet registers as WC-compatible it appears in the
 *      RainbowKit/WC modal automatically (no extra code).
 *   2. Universal-link deep-link with the WC pairing URI (scheme below) so mobile users
 *      jump straight into RH Wallet instead of scanning a QR.
 *   3. Native injected provider - RH Wallet's in-app browser injecting window.ethereum
 *      is already handled by the injected connector with no work.
 * ACTION: confirm the real scheme with Deployment (5)/GTM (7).
 */
export const ROBINHOOD_WALLET_DEEPLINK = {
  enabled: false, // flip once the scheme is confirmed
  buildLink: (wcUri: string) =>
    `https://wallet.robinhood.com/wc?uri=${encodeURIComponent(wcUri)}`,
};
