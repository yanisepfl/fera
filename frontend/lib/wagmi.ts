import { createConfig, http, cookieStorage, createStorage } from "wagmi";
import { injected, walletConnect } from "wagmi/connectors";
import { robinhoodChain } from "@/config/chains";

/**
 * wagmi config. Connectors:
 *   - injected  : MetaMask / Rabby / browser wallets (works with zero config).
 *   - walletConnect : mobile + QR — only registered when a projectId is present,
 *     otherwise WalletConnect init would throw. Set NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID.
 *   - Robinhood Wallet : deep-link, handled separately (see ROBINHOOD_WALLET_DEEPLINK +
 *     components/layout/ConnectButton.tsx). Not a wagmi connector until RH ships one.
 *
 * ssr:true + cookieStorage so `next build`/RSC never touch a wallet at render time.
 */
const wcProjectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID;

const connectors = [
  injected({ shimDisconnect: true }),
  ...(wcProjectId
    ? [
        walletConnect({
          projectId: wcProjectId,
          showQrModal: true,
          metadata: {
            name: "FERA",
            description: "Regime-aware liquidity on Robinhood Chain",
            url: "https://fera.example",
            icons: [],
          },
        }),
      ]
    : []),
];

export const wagmiConfig = createConfig({
  chains: [robinhoodChain],
  connectors,
  storage: createStorage({ storage: cookieStorage }),
  ssr: true,
  transports: {
    [robinhoodChain.id]: http(),
  },
});

/**
 * ROBINHOOD WALLET DEEP-LINK — investigation note.
 * -------------------------------------------------
 * As of build time, Robinhood Wallet exposes no public WalletConnect projectId
 * allow-list entry or documented EIP-1193 deep-link scheme we can rely on. Three
 * viable paths, in order of preference once RH confirms support:
 *
 *   1. WalletConnect v2 — if RH Wallet registers as a WC-compatible wallet, it will
 *      appear in the WC modal automatically via the connector above (no extra code).
 *   2. Universal/App link deep-link — open `https://wallet.robinhood.com/wc?uri=<enc>`
 *      (or the vendor's documented scheme) with the WC pairing URI, so mobile users
 *      jump straight into RH Wallet instead of scanning a QR. Implemented as a UI
 *      shortcut in ConnectButton (guarded behind ROBINHOOD_WALLET_DEEPLINK).
 *   3. Native injected provider — if RH Wallet's in-app browser injects
 *      window.ethereum, the `injected` connector already handles it with no work.
 *
 * ACTION: confirm the real scheme with Deployment (5)/GTM (7); until then the button
 * is shown but flagged "beta" and falls back to WalletConnect QR.
 */
export const ROBINHOOD_WALLET_DEEPLINK = {
  enabled: false, // flip once the scheme is confirmed
  buildLink: (wcUri: string) =>
    `https://wallet.robinhood.com/wc?uri=${encodeURIComponent(wcUri)}`,
};
