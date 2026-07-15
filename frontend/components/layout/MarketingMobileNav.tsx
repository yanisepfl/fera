"use client";

import { useEffect, useRef, useState } from "react";

/**
 * Mobile disclosure menu for the marketing header. The desktop nav is `hidden
 * md:flex`, so without this the Docs link and every section anchor are unreachable
 * on phones. Closes on link click, Escape, and outside click; fully keyboard-
 * operable with aria-expanded/aria-controls.
 */
export function MarketingMobileNav({
  sections,
  docsUrl,
}: {
  sections: { href: string; label: string }[];
  docsUrl: string;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("keydown", onKey);
    document.addEventListener("mousedown", onClick);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("mousedown", onClick);
    };
  }, [open]);

  const item =
    "block rounded-md px-3 py-2 text-body-sm font-medium text-dim transition-colors hover:bg-elevated hover:text-text";

  return (
    <div ref={ref} className="relative md:hidden">
      <button
        type="button"
        aria-label={open ? "Close menu" : "Open menu"}
        aria-expanded={open}
        aria-controls="marketing-mobile-menu"
        onClick={() => setOpen((v) => !v)}
        className="grid h-9 w-9 place-items-center rounded-lg border border-line bg-surface text-dim transition-colors hover:border-line-strong hover:text-text"
      >
        <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
          {open ? (
            <path
              d="M3 3l10 10M13 3L3 13"
              stroke="currentColor"
              strokeWidth="1.6"
              strokeLinecap="round"
            />
          ) : (
            <path
              d="M2 4h12M2 8h12M2 12h12"
              stroke="currentColor"
              strokeWidth="1.6"
              strokeLinecap="round"
            />
          )}
        </svg>
      </button>

      {open ? (
        <div
          id="marketing-mobile-menu"
          className="absolute right-0 top-full z-40 mt-2 w-56 rounded-lg border border-line-strong bg-well p-2 shadow-pop"
        >
          {sections.map((s) => (
            <a
              key={s.href}
              href={s.href}
              onClick={() => setOpen(false)}
              className={item}
            >
              {s.label}
            </a>
          ))}
          <a
            href={docsUrl}
            target="_blank"
            rel="noopener noreferrer"
            onClick={() => setOpen(false)}
            className={item}
          >
            Docs
          </a>
        </div>
      ) : null}
    </div>
  );
}
