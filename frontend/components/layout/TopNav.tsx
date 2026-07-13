"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/cn";
import { ConnectButton } from "./ConnectButton";

/**
 * Flagship pool the "Pool" tab lands on. Pool detail is inherently per-pool
 * (/pool/[poolId]); there is no pools-index route (Earn is the list), so the nav
 * entry deep-links to the featured NVDA/USDG pool. Active for any /pool/* path.
 */
const FEATURED_POOL =
  "0x0000000000000000000000000000000000000000000000000000000000000001";

const NAV: { href: string; label: string; match: (p: string) => boolean }[] = [
  { href: "/app", label: "Earn", match: (p) => p === "/app" },
  { href: `/app/pool/${FEATURED_POOL}`, label: "Pool", match: (p) => p.startsWith("/app/pool") },
  { href: "/app/rewards", label: "Rewards", match: (p) => p.startsWith("/app/rewards") },
  { href: "/app/swap", label: "Swap", match: (p) => p.startsWith("/app/swap") },
  { href: "/app/transparency", label: "Transparency", match: (p) => p.startsWith("/app/transparency") },
];

export function TopNav() {
  const pathname = usePathname();
  return (
    <header className="sticky top-0 z-30 border-b border-line bg-well/80 backdrop-blur-md">
      <div className="mx-auto flex h-14 max-w-app items-center gap-6 px-4 md:px-6">
        <Link href="/app" className="flex items-center gap-2 shrink-0">
          <span
            className="grid h-6 w-6 place-items-center rounded-md text-[13px] font-bold"
            style={{ background: "var(--accent)", color: "var(--on-accent)" }}
          >
            F
          </span>
          <span className="text-heading font-semibold tracking-tight">FERA</span>
        </Link>

        <nav className="hidden md:flex items-center gap-1">
          {NAV.map((n) => (
            <Link
              key={n.href}
              href={n.href}
              className={cn(
                "rounded-md px-3 py-1.5 text-body-sm font-medium transition-colors",
                n.match(pathname)
                  ? "bg-hover text-text"
                  : "text-mute hover:text-dim hover:bg-elevated"
              )}
            >
              {n.label}
            </Link>
          ))}
        </nav>

        <div className="ml-auto flex items-center gap-2">
          <ConnectButton />
        </div>
      </div>

      {/* mobile nav */}
      <nav className="md:hidden flex items-center gap-1 overflow-x-auto border-t border-line px-2 py-1.5">
        {NAV.map((n) => (
          <Link
            key={n.href}
            href={n.href}
            className={cn(
              "shrink-0 rounded-md px-3 py-1.5 text-body-sm font-medium transition-colors",
              n.match(pathname)
                ? "bg-hover text-text"
                : "text-mute hover:text-dim"
            )}
          >
            {n.label}
          </Link>
        ))}
      </nav>
    </header>
  );
}
