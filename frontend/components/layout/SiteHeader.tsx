import Link from "next/link";
import { Logo } from "@/components/ui/Logo";

/**
 * SiteHeader - the ONE header shell shared by the marketing landing ("/") and the
 * app ("/app/*"), so both wear the same chrome: sticky h-16 bar, hairline border,
 * blurred well surface, and the green BrandLockup on the left. Each surface fills
 * the slots with its own links/actions:
 *
 *   - `nav`    - centered links (desktop only; each surface handles mobile).
 *   - `right`  - right-aligned actions (Launch App CTA / wallet ConnectButton).
 *   - `below`  - optional full-width row under the bar (the app's mobile tabs).
 *
 * Server-component-safe: no hooks here; interactive bits live in the slots.
 */
export function SiteHeader({
  brandHref = "/",
  nav,
  right,
  below,
}: {
  /** Where the brand lockup links to ("/" on marketing, "/app" in the app). */
  brandHref?: string;
  nav?: React.ReactNode;
  right?: React.ReactNode;
  below?: React.ReactNode;
}) {
  return (
    <header className="sticky top-0 z-30 border-b border-line bg-well/80 backdrop-blur-md">
      <div className="mx-auto flex h-16 max-w-app items-center gap-3 px-4 md:gap-6 md:px-6">
        <BrandLockup href={brandHref} />
        {nav}
        <div className="ml-auto flex items-center gap-3">{right}</div>
      </div>
      {below}
    </header>
  );
}

/** Shared nav-link treatment: quiet text with a green underline that wipes in on
 *  hover (reduced-motion: appears instantly). `navLinkActive` pins it on. */
export const navLinkClass =
  "relative px-1 py-1 text-body-sm font-medium text-mute transition-colors hover:text-text " +
  "after:pointer-events-none after:absolute after:inset-x-0 after:-bottom-0.5 after:h-px " +
  "after:origin-left after:scale-x-0 after:bg-accent after:transition-transform after:duration-fast " +
  "after:ease-out hover:after:scale-x-100 focus-visible:after:scale-x-100";
export const navLinkActiveClass = "text-text after:scale-x-100";

/** Logo + FERA wordmark: the claw mark in a soft green-wash tile, the wordmark in
 *  the green brand gradient - the brand signature, identical on every surface. */
export function BrandLockup({ href = "/" }: { href?: string }) {
  return (
    <Link href={href} className="group flex shrink-0 items-center gap-2.5">
      <span className="grid h-8 w-8 place-items-center rounded-lg border border-accent-line bg-accent-wash transition-colors duration-fast group-hover:border-accent">
        <Logo className="h-5 w-5" />
      </span>
      <Wordmark />
    </Link>
  );
}

/** FERA wordmark with the green brand gradient (brand signature). */
export function Wordmark() {
  return (
    <span
      className="text-heading font-semibold tracking-tight"
      style={{
        backgroundImage:
          "linear-gradient(180deg, #5cefad 0%, #2fe08a 55%, #159a5c 100%)",
        WebkitBackgroundClip: "text",
        backgroundClip: "text",
        WebkitTextFillColor: "transparent",
        color: "transparent",
      }}
    >
      FERA
    </span>
  );
}
