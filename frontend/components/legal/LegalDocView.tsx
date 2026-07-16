import Link from "next/link";
import type { LegalDoc } from "@/lib/legal/content";
import { LEGAL_DOCS, LEGAL_ORDER, LEGAL_UPDATED, LEGAL_VERSION } from "@/lib/legal/content";

/**
 * Renders a canonical legal document (lib/legal/content.ts) as a readable on-site page.
 * The exact same structured content backs the generated PDFs, so the web route and the
 * PDF never diverge. Server-component-safe (no hooks).
 */
export function LegalDocView({ doc }: { doc: LegalDoc }) {
  return (
    <article className="mx-auto w-full max-w-3xl px-4 py-10 md:px-6 md:py-14">
      <nav className="mb-8 flex flex-wrap items-center gap-x-2 gap-y-1 text-body-sm">
        {LEGAL_ORDER.map((id, i) => {
          const d = LEGAL_DOCS[id];
          const active = id === doc.id;
          return (
            <span key={id} className="flex items-center gap-2">
              {i > 0 ? <span className="text-mute">·</span> : null}
              <Link
                href={`/legal/${id}`}
                className={
                  active
                    ? "font-medium text-text"
                    : "text-mute transition-colors hover:text-text"
                }
                aria-current={active ? "page" : undefined}
              >
                {d.title}
              </Link>
            </span>
          );
        })}
      </nav>

      <header className="border-b border-line pb-6">
        <div className="overline overline-gold mb-2">FERA Legal</div>
        <h1 className="text-display-l font-semibold tracking-tight text-text">{doc.title}</h1>
        <p className="mt-3 text-body text-dim">{doc.summary}</p>
        <div className="mt-4 flex flex-wrap items-center gap-x-4 gap-y-1 text-caption text-mute">
          <span>Last updated {LEGAL_UPDATED}</span>
          <span>Version {LEGAL_VERSION}</span>
          <a
            href={`/legal/${doc.id}.pdf`}
            target="_blank"
            rel="noopener noreferrer"
            className="font-medium text-accent underline-offset-2 hover:text-accent-strong hover:underline"
          >
            Download PDF
          </a>
        </div>
      </header>

      <div className="mt-8 space-y-8">
        {doc.sections.map((s) => (
          <section key={s.heading}>
            <h2 className="text-heading font-semibold tracking-tight text-text">{s.heading}</h2>
            <div className="mt-2 space-y-3">
              {s.body.map((b, i) =>
                Array.isArray(b) ? (
                  <ul key={i} className="ml-4 list-disc space-y-1.5 text-body-sm text-dim">
                    {b.map((item, j) => (
                      <li key={j}>{item}</li>
                    ))}
                  </ul>
                ) : (
                  <p key={i} className="text-body-sm leading-relaxed text-dim">
                    {b}
                  </p>
                ),
              )}
            </div>
          </section>
        ))}
      </div>

      <footer className="mt-12 border-t border-line pt-6 text-caption text-mute">
        <p>
          This document is provided by the pre-incorporation FERA project. It is not legal
          advice and does not create a professional relationship. FERA is not affiliated
          with Robinhood.
        </p>
        <p className="mt-3">
          <Link href="/app" className="text-accent hover:text-accent-strong">
            &larr; Back to the app
          </Link>
        </p>
      </footer>
    </article>
  );
}
