"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/cn";
import {
  SiteHeader,
  navLinkClass,
  navLinkActiveClass,
} from "@/components/layout/SiteHeader";
import { ConnectButton } from "./ConnectButton";

/**
 * App top nav, built on the shared SiteHeader shell so it wears the exact same
 * chrome as the marketing header: h-16 bar, gold BrandLockup, centered links with
 * the gold underline treatment (pinned on for the active route), actions right.
 *
 * Flagship pool the "Pool" tab lands on. Pool detail is inherently per-pool
 * (/pool/[poolId]); there is no pools-index route (Earn is the list), so the nav
 * entry deep-links to the featured MEME pool (PEPE/WETH). Active for any /pool/* path.
 */
const FEATURED_POOL =
  "0x0000000000000000000000000000000000000000000000000000000000000002";

const NAV: { href: string; label: string; match: (p: string) => boolean }[] = [
  { href: "/app", label: "Earn", match: (p) => p === "/app" },
  { href: `/app/pool/${FEATURED_POOL}`, label: "Pool", match: (p) => p.startsWith("/app/pool") },
  { href: "/app/rewards", label: "Rewards", match: (p) => p.startsWith("/app/rewards") },
];

export function TopNav() {
  const pathname = usePathname();
  return (
    <SiteHeader
      brandHref="/app"
      nav={
        <nav className="hidden min-w-0 flex-1 items-center justify-center gap-6 md:flex">
          {NAV.map((n) => (
            <Link
              key={n.href}
              href={n.href}
              className={cn(navLinkClass, n.match(pathname) && navLinkActiveClass)}
            >
              {n.label}
            </Link>
          ))}
        </nav>
      }
      right={<ConnectButton />}
      below={
        <nav className="flex items-center gap-1 overflow-x-auto border-t border-line px-2 py-1.5 md:hidden">
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
      }
    />
  );
}
