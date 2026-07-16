import Link from "next/link";
import { SiteHeader } from "@/components/layout/SiteHeader";

/**
 * Chrome for the /legal/* routes: the shared SiteHeader (brand → home) with a single
 * Launch App action, then the document. Kept server-component-simple; the docs render the
 * canonical content from lib/legal/content.ts.
 */
export default function LegalLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen">
      <SiteHeader
        brandHref="/"
        right={
          <Link
            href="/app"
            className="inline-flex h-9 items-center justify-center gap-1.5 whitespace-nowrap rounded-lg bg-accent2 px-3 text-body-sm font-medium text-accent2-fg shadow-glow-accent2 transition-colors duration-fast hover:bg-accent2-strong active:bg-accent2-dim sm:px-4"
          >
            Launch App
          </Link>
        }
      />
      <main>{children}</main>
    </div>
  );
}
