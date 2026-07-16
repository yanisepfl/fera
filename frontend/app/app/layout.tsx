import Link from "next/link";
import { TopNav } from "@/components/layout/TopNav";

/**
 * App shell (URL segment /app/*). Holds the chrome that used to live in the root
 * layout: the sticky TopNav (with the wallet ConnectButton) and the width-capped
 * main, plus a slim legal footer so the Terms/Privacy/Risk docs are always reachable
 * from inside the app (they're also linked from the first-connect ToS gate).
 */
export default function AppLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
      <TopNav />
      <main className="mx-auto w-full max-w-app px-4 py-6 md:px-6 md:py-10">
        {children}
      </main>
      <footer className="border-t border-line">
        <div className="mx-auto flex w-full max-w-app flex-col gap-3 px-4 py-6 text-caption text-mute sm:flex-row sm:items-center sm:justify-between md:px-6">
          <span>
            &copy; 2026 FERA · experimental, unaudited, non-custodial software · not
            affiliated with Robinhood
          </span>
          <nav className="flex flex-wrap items-center gap-x-4 gap-y-1">
            <Link href="/legal/terms" className="transition-colors hover:text-text">
              Terms
            </Link>
            <Link href="/legal/privacy" className="transition-colors hover:text-text">
              Privacy
            </Link>
            <Link href="/legal/risk" className="transition-colors hover:text-text">
              Risk Disclosure
            </Link>
          </nav>
        </div>
      </footer>
    </>
  );
}
