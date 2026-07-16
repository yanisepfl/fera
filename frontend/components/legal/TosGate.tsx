"use client";

import { useEffect, useId, useState } from "react";
import Link from "next/link";
import { Button } from "@/components/ui/Button";
import { shortHex } from "@/lib/format";
import { useAccount } from "wagmi";

/**
 * The Terms-of-Service acceptance gate — a blocking, non-dismissible overlay shown after
 * the first wallet connect until the user signs (or disconnects). It is intentionally NOT
 * closable by Escape or backdrop click: the only ways out are "Accept" (which triggers the
 * wallet signature) or "Disconnect". Gold-accented to match the FERA brand; the accept
 * action carries the green action accent per the design system.
 */
export function TosGate({
  version,
  signing,
  error,
  onAccept,
  onDisconnect,
}: {
  version: string;
  signing: boolean;
  error: string | null;
  onAccept: () => void;
  onDisconnect: () => void;
}) {
  const [checked, setChecked] = useState(false);
  const { address } = useAccount();
  const titleId = useId();

  // Lock body scroll while the gate is up.
  useEffect(() => {
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = prev;
    };
  }, []);

  const RISKS = [
    "FERA is experimental, unaudited, non-custodial software — you can lose all deposited assets.",
    "Providing liquidity on volatile assets carries impermanent loss and loss-versus-rebalancing.",
    "Fees are variable and never guaranteed; there is no fixed yield and no promised return.",
    "Access may be restricted or paused, and parameters may change. Your compliance is your responsibility.",
  ];

  return (
    <div
      className="fixed inset-0 z-[100] grid place-items-end sm:place-items-center"
      role="dialog"
      aria-modal="true"
      aria-labelledby={titleId}
    >
      {/* Non-interactive backdrop: no onClick — the gate is dismissible only by acting. */}
      <div className="absolute inset-0 bg-black/70 backdrop-blur-sm" aria-hidden />

      <div className="relative z-10 w-full sm:max-w-lg overflow-hidden rounded-t-lg sm:rounded-lg border border-line-strong bg-raised shadow-pop animate-fade-up">
        {/* gold top hairline — brand signature */}
        <div
          aria-hidden
          className="h-1 w-full"
          style={{
            backgroundImage:
              "linear-gradient(90deg, #cd9f33 0%, #e7b84b 50%, #f3d488 100%)",
          }}
        />

        <div className="max-h-[85vh] overflow-y-auto p-5 sm:p-6 space-y-4">
          <div>
            <div className="overline overline-gold mb-1.5">One-time step</div>
            <h2 id={titleId} className="text-heading font-semibold tracking-tight text-text">
              Accept the Terms to continue
            </h2>
            <p className="mt-2 text-body-sm text-dim">
              Before you can deposit, withdraw, stake, or claim, please review and accept
              the FERA Terms. You&apos;ll confirm with a wallet signature — this is a
              signature, not a transaction, so it costs no gas and nothing moves.
            </p>
          </div>

          {/* risk summary */}
          <ul className="space-y-1.5 rounded-lg border border-line bg-well p-3">
            {RISKS.map((r) => (
              <li key={r} className="flex gap-2 text-body-sm text-dim">
                <span aria-hidden className="mt-2 h-1 w-1 shrink-0 rounded-full bg-accent" />
                <span>{r}</span>
              </li>
            ))}
          </ul>

          {/* full documents */}
          <div className="flex flex-wrap gap-x-4 gap-y-1 text-body-sm">
            <span className="text-mute">Read in full:</span>
            <LegalLink href="/legal/terms">Terms of Service</LegalLink>
            <LegalLink href="/legal/privacy">Privacy Policy</LegalLink>
            <LegalLink href="/legal/risk">Risk Disclosure</LegalLink>
          </div>

          {/* accept checkbox */}
          <label className="flex items-start gap-2.5 rounded-lg border border-line bg-surface p-3 text-body-sm text-dim">
            <input
              type="checkbox"
              checked={checked}
              onChange={(e) => setChecked(e.target.checked)}
              className="mt-0.5 h-4 w-4 accent-[var(--accent2)]"
            />
            <span>
              I have read and accept the Terms of Service, Privacy Policy, and Risk
              Disclosure, and I understand FERA is experimental software and I may lose all
              deposited assets.
            </span>
          </label>

          {error ? (
            <div className="rounded-lg border border-danger-line bg-danger-wash p-3 text-body-sm text-text">
              {error}
            </div>
          ) : null}

          <div className="flex flex-col gap-2 sm:flex-row-reverse">
            <Button
              className="w-full sm:flex-1"
              size="lg"
              disabled={!checked || signing}
              onClick={onAccept}
            >
              {signing ? "Confirm in your wallet…" : "Accept & sign"}
            </Button>
            <Button
              variant="secondary"
              size="lg"
              className="w-full sm:w-auto"
              onClick={onDisconnect}
              disabled={signing}
            >
              Disconnect
            </Button>
          </div>

          <p className="text-micro text-mute">
            Terms version {version}
            {address ? (
              <>
                {" "}
                · <span className="font-mono">{shortHex(address)}</span>
              </>
            ) : null}
          </p>
        </div>
      </div>
    </div>
  );
}

function LegalLink({ href, children }: { href: string; children: React.ReactNode }) {
  return (
    <Link
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className="font-medium text-accent underline-offset-2 hover:text-accent-strong hover:underline"
    >
      {children}
    </Link>
  );
}
