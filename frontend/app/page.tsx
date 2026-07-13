import Link from "next/link";
import { Logo } from "@/components/ui/Logo";

/**
 * Marketing landing (front door, "/"). alphix-family aesthetic: dark-first,
 * typography-led, one accent (Fera Gold), calm and precise, no hype. Reuses the
 * in-family tokens (DESIGN.md). Copy is drawn from docs/gtm/POSITIONING.md and holds
 * the load-bearing honest-framing constraints (D-M13 / D-18 / R-8): the vault is sold
 * as managed + emissions-eligible + simple, NEVER as higher-yield than a self-managed
 * LP; no "tranche" / "dividend" / "guaranteed yield"; every number is on-chain
 * reproducible or it isn't stated. The app itself lives under /app.
 */

// Anchor-styled links that reuse the Button visual language without a client handler.
const btnBase =
  "inline-flex items-center justify-center font-medium whitespace-nowrap select-none transition-[background,color,border,box-shadow] duration-fast ease-out rounded-lg h-12 px-6 text-body gap-2";
const btnPrimary = `${btnBase} bg-accent text-accent-fg hover:bg-accent-strong active:bg-accent-dim shadow-glow-accent`;
const btnSecondary = `${btnBase} bg-surface text-text border border-line hover:border-line-strong hover:bg-raised`;

export default function LandingPage() {
  return (
    <div className="min-h-screen">
      <MarketingHeader />

      <main>
        <Hero />
        <HowItWorks />
        <Narratives />
        <HonestFraming />
        <Transparency />
        <CtaBand />
      </main>

      <MarketingFooter />
    </div>
  );
}

/* ------------------------------------------------------------------ header ---- */

function MarketingHeader() {
  return (
    <header className="sticky top-0 z-30 border-b border-line bg-well/80 backdrop-blur-md">
      <div className="mx-auto flex h-14 max-w-app items-center gap-6 px-4 md:px-6">
        <Link href="/" className="flex items-center gap-2 shrink-0">
          <Logo className="h-6 w-6" />
          <span className="text-heading font-semibold tracking-tight">FERA</span>
        </Link>

        <nav className="hidden items-center gap-1 md:flex">
          {[
            { href: "#how", label: "How it works" },
            { href: "#narratives", label: "Narratives" },
            { href: "#transparency", label: "Transparency" },
          ].map((n) => (
            <a
              key={n.href}
              href={n.href}
              className="rounded-md px-3 py-1.5 text-body-sm font-medium text-mute transition-colors hover:bg-elevated hover:text-dim"
            >
              {n.label}
            </a>
          ))}
        </nav>

        <div className="ml-auto flex items-center gap-2">
          <Link
            href="/app"
            className="inline-flex h-8 items-center justify-center gap-1.5 rounded-sm bg-accent px-3 text-body-sm font-medium text-accent-fg shadow-glow-accent transition-colors duration-fast hover:bg-accent-strong active:bg-accent-dim"
          >
            Launch App
          </Link>
        </div>
      </div>
    </header>
  );
}

/* -------------------------------------------------------------------- hero ---- */

function Hero() {
  return (
    <section className="relative overflow-hidden border-b border-line">
      {/* soft top-crown glow, the lifted premium-dark trait, static/reduced-motion-safe */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 h-[420px]"
        style={{
          background:
            "radial-gradient(60% 100% at 50% -10%, rgba(231,184,75,0.10) 0%, rgba(231,184,75,0) 60%)",
        }}
      />
      <div className="relative mx-auto max-w-app px-4 py-20 md:px-6 md:py-28">
        <div className="max-w-3xl">
          <div
            className="mb-5 inline-flex items-center gap-2 rounded-full border px-3 py-1"
            style={{ borderColor: "rgba(70,192,138,0.28)", background: "rgba(70,192,138,0.08)" }}
          >
            <span
              className="h-1.5 w-1.5 rounded-full"
              style={{ background: "#46c08a", boxShadow: "0 0 8px rgba(70,192,138,0.75)" }}
            />
            <span className="text-micro uppercase tracking-[0.08em]" style={{ color: "#8fd9b6" }}>
              Live on Robinhood Chain
            </span>
          </div>

          <h1 className="text-[2.5rem] font-semibold leading-[1.05] tracking-[-0.02em] text-text md:text-[4rem]">
            Earn on Robinhood Chain, the easy way.
          </h1>

          <p className="mt-6 max-w-2xl text-body text-dim md:text-heading md:leading-8">
            FERA pools charge volatile, bot-driven trades a higher fee. The flow that
            usually drains liquidity providers earns for ours instead.
          </p>

          <div className="mt-9 flex flex-col gap-3 sm:flex-row">
            <Link href="/app" className={btnPrimary}>
              Launch App
              <span aria-hidden>→</span>
            </Link>
            <a href="#how" className={btnSecondary}>
              How it works
            </a>
          </div>

          <p className="mt-6 text-caption text-mute">
            On-chain-verifiable, immutable, permissionless. Zero FERA swap fees.
          </p>
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------- how it works ---- */

const STEPS = [
  {
    n: "01",
    t: "Regime-Aware Liquidity",
    d: "Our v4 hooked pools set the LP fee per swap. MEME pools scale the fee with realized volatility; RWA pools widen it off-hours and track the Chainlink feed. The more mechanical the flow, the more LPs earn. All transparent on-chain and immutable.",
  },
  {
    n: "02",
    t: "Fera Vaults",
    d: "Deposit into our vault and forget the hassle of position management. Rule-based, zero-discretion strategies within hardcoded bounds. Pick a risk profile: Steady (wide, conservative) or Active (concentrated, more fee capture).",
  },
  {
    n: "03",
    t: "Earn",
    d: "Collect yield plus esFERA emissions on your vault shares. A 10% performance fee applies only to fees you actually earn, never on principal, deposits, withdrawals, or swaps. Half of it flows back to FERA stakers.",
  },
];

function HowItWorks() {
  return (
    <section id="how" className="border-b border-line">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline mb-3">How it works</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          Smart fees price the risk. Vaults make it effortless. You keep the yield.
        </h2>

        <div className="mt-10 grid gap-4 md:grid-cols-3">
          {STEPS.map((s) => (
            <div
              key={s.n}
              className="rounded-lg border border-line bg-card p-6 shadow-card"
            >
              <div className="font-mono text-caption text-accent">{s.n}</div>
              <div className="mt-3 text-heading font-semibold text-text">{s.t}</div>
              <p className="mt-2 text-body-sm text-dim">{s.d}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

/* -------------------------------------------------------------- narratives ---- */

const NARRATIVES = [
  {
    tag: "Comparative fee capture",
    t: "Our pool vs a vanilla pool, on the same path.",
    d: "Take the same position over the same price path. Impermanent loss is identical in a FERA pool and a vanilla one, so the whole difference comes down to fees. The regime fee captures more of the flow that actually matters.",
    honest:
      "This compares our pool to a vanilla pool (the fee mechanism), net of the 10% performance fee. It is not the vault against a self-managed LP. Any comparison ships only once anyone can reproduce it on real chain data.",
  },
  {
    tag: "Weekend drift → yield",
    t: "Your LP position earns the arbitrage instead of feeding it.",
    d: "Tokenized stocks trade 24/7, but the real equities don't. Prices drift over the weekend and snap back at Monday's open. For a vanilla LP, that snap-back is a steady, structural loss. The RWA regime turns it into LP income instead.",
    honest:
      "Steady, but not guaranteed. A quiet weekend earns little, and a large Monday gap still costs the position. We say “earns the arbitrage,” never “earns you X%.”",
  },
  {
    tag: "Bot monetization",
    t: "We don't fight bots. We invoice them.",
    d: "On a first-come-first-served chain with no priority-fee auction, wash, volume, and MEV bots are just flow. The MEME regime prices them. The more violent and one-sided the flow, the higher the fee. Bots become fee fountains by design.",
    honest:
      "We price toxic swap flow through fees. We do not claim to capture the MEV itself. Internalizing top-of-block MEV is a v2 goal, not v1.",
  },
];

function Narratives() {
  return (
    <section id="narratives" className="border-b border-line">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline mb-3">The mechanism, three ways</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          We monetize the flow that bleeds ordinary LPs.
        </h2>

        <div className="mt-10 space-y-4">
          {NARRATIVES.map((x) => (
            <div
              key={x.tag}
              className="rounded-lg border border-line bg-card p-6 shadow-card md:flex md:gap-8 md:p-8"
            >
              <div className="md:w-64 md:shrink-0">
                <div className="inline-flex rounded-full bg-accent-wash px-2.5 py-1 text-micro uppercase tracking-[0.08em] text-accent">
                  {x.tag}
                </div>
                <h3 className="mt-3 text-title font-semibold tracking-tight text-text">
                  {x.t}
                </h3>
              </div>
              <div className="mt-4 flex-1 md:mt-0">
                <p className="text-body text-dim">{x.d}</p>
                <p className="mt-3 border-l-2 border-line-strong pl-3 text-body-sm text-mute">
                  <span className="font-medium text-dim">The honest line:</span>{" "}
                  {x.honest}
                </p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

/* ----------------------------------------------------------- honest framing ---- */

const CLAIMS = [
  {
    t: "The vault is managed, not magic.",
    d: "What you get is management, emissions eligibility, simplicity, and a risk profile to pick. What you don't get is a promise that the vault beats a skilled self-managed LP. It doesn't, and we won't pretend otherwise.",
  },
  {
    t: "No tranches, no dividends, no fixed yield.",
    d: "Risk profiles are “Steady” and “Active.” Staker rewards are a variable revenue share tied to protocol activity. We never say “tranche,” “dividend,” “guaranteed,” or “risk-free.”",
  },
  {
    t: "Emissions can't out-print revenue.",
    d: "Weekly esFERA issuance is capped by protocol revenue (β-cap, INV-7) and split 85/5/10 across LPs, traders, and treasury. Issuance follows activity. It is not a subsidy.",
  },
  {
    t: "If we can't point to the transaction, we don't say it.",
    d: "Every number we publish is reproducible by anyone from on-chain events. Preliminary or synthetic figures are labeled as such and never quoted as live results.",
  },
];

function HonestFraming() {
  return (
    <section className="border-b border-line bg-well">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline mb-3">What we will and won&apos;t claim</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          Precise beats loud.
        </h2>
        <p className="mt-3 max-w-2xl text-body text-dim">
          The discipline below is load-bearing, not decoration. Bunni, Gamma, and
          Cork all shipped and still died. Humility is the only credible posture.
        </p>

        <div className="mt-10 grid gap-4 sm:grid-cols-2">
          {CLAIMS.map((c) => (
            <div
              key={c.t}
              className="rounded-lg border border-line bg-card p-6 shadow-card"
            >
              <div className="text-body font-semibold text-text">{c.t}</div>
              <p className="mt-2 text-body-sm text-dim">{c.d}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------- transparency ---- */

function Transparency() {
  return (
    <section id="transparency" className="border-b border-line">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="rounded-lg border border-accent-line bg-card p-8 shadow-glow-accent md:p-10">
          <div className="overline mb-3">Verifiable by construction</div>
          <h2 className="max-w-2xl text-title font-semibold tracking-tight text-text md:text-display-l">
            Every fee, every emission, reproducible from on-chain data.
          </h2>
          <p className="mt-3 max-w-2xl text-body text-dim">
            Hook <span className="font-mono text-dim">afterSwap</span> events and vault
            fee-collection events flow through an indexer into weekly Merkle roots posted
            on-chain. Anyone can recompute a root and check the split for themselves: 50 / 25 / 25
            of real revenue to stakers, treasury, and ops, and 85 / 5 / 10 of emissions to LPs,
            traders, and treasury. Once an epoch is posted, it is never hotfixed.
          </p>
          <div className="mt-6">
            <Link
              href="/app/transparency"
              className="inline-flex items-center gap-1.5 text-body-sm font-medium text-accent hover:text-accent-strong"
            >
              Open the Transparency page <span aria-hidden>→</span>
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}

/* ---------------------------------------------------------------- cta band ---- */

function CtaBand() {
  return (
    <section className="border-b border-line">
      <div className="mx-auto max-w-app px-4 py-20 text-center md:px-6 md:py-28">
        <h2 className="mx-auto max-w-2xl text-display-l font-semibold tracking-tight text-text md:text-display-xl">
          LP where every flow pays you.
        </h2>
        <p className="mx-auto mt-3 max-w-xl text-body text-dim">
          Deposit into a managed vault, hold a normal ERC-20 share, and earn fee yield
          plus esFERA on the pools you already believe in.
        </p>
        <div className="mt-8 flex justify-center">
          <Link href="/app" className={btnPrimary}>
            Launch App
            <span aria-hidden>→</span>
          </Link>
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------ footer ---- */

function MarketingFooter() {
  return (
    <footer className="bg-well">
      <div className="mx-auto max-w-app px-4 py-12 md:px-6">
        <div className="flex flex-col gap-8 md:flex-row md:items-start md:justify-between">
          <div className="max-w-sm">
            <div className="flex items-center gap-2">
              <Logo className="h-6 w-6" />
              <span className="text-heading font-semibold tracking-tight">FERA</span>
            </div>
            <p className="mt-3 text-body-sm text-dim">
              LP-first, regime-aware liquidity on Robinhood Chain.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-8 sm:grid-cols-3">
            <FooterCol
              title="Product"
              links={[
                { href: "/app", label: "Launch App" },
                { href: "/app", label: "Earn" },
                { href: "/app/transparency", label: "Transparency" },
              ]}
            />
            <FooterCol
              title="Learn"
              links={[
                { href: "#how", label: "How it works" },
                { href: "#narratives", label: "Narratives" },
                {
                  href: "https://fera-3.gitbook.io/fera/",
                  label: "Docs",
                  external: true,
                },
                {
                  href: "https://fera-3.gitbook.io/fera/for-projects",
                  label: "For projects",
                  external: true,
                },
              ]}
            />
            <FooterCol
              title="Build"
              links={[
                {
                  href: "https://github.com/yanisepfl/fera",
                  label: "GitHub",
                  external: true,
                },
                {
                  href: "https://robinhoodchain.blockscout.com",
                  label: "Explorer",
                  external: true,
                },
              ]}
            />
          </div>
        </div>

        <div className="hr my-8" />

        <p className="max-w-3xl text-caption text-mute">
          FERA is LP-first infrastructure. It provides liquidity tooling, not
          securities. Swaps are never gated and never charged a protocol fee (INV-2).
          RWA-pool deposits are geo-fenced by config. Nothing here is an offer, a
          solicitation, or investment advice. There is no guaranteed yield. Every number is
          reproducible from on-chain data via the Transparency page (MASTER_SPEC §9).
        </p>
      </div>
    </footer>
  );
}

function FooterCol({
  title,
  links,
}: {
  title: string;
  links: { href: string; label: string; external?: boolean }[];
}) {
  return (
    <div>
      <div className="overline mb-3">{title}</div>
      <ul className="space-y-2">
        {links.map((l) => (
          <li key={l.label}>
            {l.external ? (
              <a
                href={l.href}
                target="_blank"
                rel="noopener noreferrer"
                className="text-body-sm text-dim transition-colors hover:text-text"
              >
                {l.label}
              </a>
            ) : (
              <Link
                href={l.href}
                className="text-body-sm text-dim transition-colors hover:text-text"
              >
                {l.label}
              </Link>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}
