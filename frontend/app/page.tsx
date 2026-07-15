import Link from "next/link";
import { Logo } from "@/components/ui/Logo";
import { FeatherBand, BandDivider } from "@/components/ui/FeatherBand";
import { LpOutcomeChart, FeeResponseChart } from "@/components/viz";
import { MarketingMobileNav } from "@/components/layout/MarketingMobileNav";

/**
 * Marketing landing (front door, "/"). Concept: FERA democratizes market-making.
 * Robinhood democratized trading; FERA opens the market-maker seat - the side that
 * earns the fees - to everyone. Dark-first, one confident green accent + neutrals,
 * the gold FERA mark retained as the heritage brand mark. Mobile-first fintech energy.
 *
 * HONESTY (load-bearing): the vault is sold as managed + simple, NEVER as higher-yield
 * than a skilled self-managed LP. No "guaranteed" / "risk-free" / fixed yield. Risk
 * levels are Steady / Active (never "tranche"). Any figure that isn't live on-chain
 * data is visibly illustrative (the two viz cards carry their own honest framing). No
 * internal jargon (no "toxic flow", "regime", "TWAP", "LVR") in rendered copy.
 * Emissions / fee-split percentages are intentionally out of scope here. The app itself
 * lives under /app; nothing is live yet (see the "Launching on Robinhood Chain" badge).
 */

const DOCS_URL = "https://fera-3.gitbook.io/fera/";
const GITHUB_URL = "https://github.com/yanisepfl/fera";

// Anchor-styled links that reuse the Button visual language without a client handler.
const btnBase =
  "inline-flex items-center justify-center font-medium whitespace-nowrap select-none transition-[background,color,border,box-shadow] duration-fast ease-out rounded-lg h-12 px-6 text-body gap-2";
const btnPrimary = `${btnBase} bg-accent text-accent-fg hover:bg-accent-strong active:bg-accent-dim shadow-glow-accent`;
const btnSecondary = `${btnBase} bg-surface text-text border border-line hover:border-line-strong hover:bg-raised`;

// Section anchors, shared by the header nav + footer so nothing is orphaned.
const SECTIONS = [
  { href: "#how", label: "How it works" },
  { href: "#why", label: "Why it earns" },
  { href: "#levels", label: "Risk levels" },
  { href: "#chain", label: "Robinhood Chain" },
];

export default function LandingPage() {
  return (
    <div className="min-h-screen">
      <MarketingHeader />

      <main>
        <Hero />
        <HowItWorks />
        <WhyItEarns />
        <RiskLevels />
        <HonestFraming />
        <RobinhoodChain />
        <Verifiable />
        <BandDivider className="py-6" />
        <CtaBand />
      </main>

      <MarketingFooter />
    </div>
  );
}

/* ------------------------------------------------------------------ header ---- */

// Animated green underline that wipes in on hover (reduced-motion: appears instantly).
const navLink =
  "relative px-1 py-1 text-body-sm font-medium text-mute transition-colors hover:text-text " +
  "after:pointer-events-none after:absolute after:inset-x-0 after:-bottom-0.5 after:h-px " +
  "after:origin-left after:scale-x-0 after:bg-accent after:transition-transform after:duration-fast " +
  "after:ease-out hover:after:scale-x-100 focus-visible:after:scale-x-100";

function MarketingHeader() {
  return (
    <header className="sticky top-0 z-30 border-b border-line bg-well/80 backdrop-blur-md">
      <div className="mx-auto flex h-16 max-w-app items-center gap-6 px-4 md:px-6">
        <BrandLockup />

        {/* Centered nav balances the header on wide viewports. */}
        <nav className="hidden flex-1 items-center justify-center gap-6 md:flex">
          {SECTIONS.map((n) => (
            <a key={n.href} href={n.href} className={navLink}>
              {n.label}
            </a>
          ))}
          <a
            href={DOCS_URL}
            target="_blank"
            rel="noopener noreferrer"
            className={navLink}
          >
            Docs
          </a>
        </nav>

        <div className="ml-auto flex items-center gap-3">
          <Link
            href="/app"
            className="inline-flex h-9 items-center justify-center gap-1.5 rounded-lg bg-accent px-4 text-body-sm font-medium text-accent-fg shadow-glow-accent transition-colors duration-fast hover:bg-accent-strong active:bg-accent-dim"
          >
            Launch App
          </Link>
          <MarketingMobileNav sections={SECTIONS} docsUrl={DOCS_URL} />
        </div>
      </div>
    </header>
  );
}

/** Logo + FERA wordmark. The mark sits in a soft gold-wash tile and the wordmark
 *  carries the warm gold gradient: the retained heritage brand mark, against the
 *  green UI accent. */
function BrandLockup() {
  return (
    <Link href="/" className="group flex shrink-0 items-center gap-2.5">
      <span className="grid h-8 w-8 place-items-center rounded-lg border border-accent2-line bg-accent2-wash transition-colors duration-fast group-hover:border-accent2">
        <Logo className="h-5 w-5" />
      </span>
      <Wordmark />
    </Link>
  );
}

/** FERA wordmark with the warm gold gradient (brand signature). */
function Wordmark() {
  return (
    <span
      className="text-heading font-semibold tracking-tight"
      style={{
        backgroundImage:
          "linear-gradient(180deg, #f3d488 0%, #e7b84b 55%, #cd9f33 100%)",
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

/* -------------------------------------------------------------------- hero ---- */

function Hero() {
  return (
    <section className="relative overflow-hidden border-b border-line">
      {/* soft top-crown glow (green) - the lifted premium-dark trait, reduced-motion-safe */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 h-[420px]"
        style={{
          background:
            "radial-gradient(60% 100% at 50% -10%, rgba(46,207,136,0.10) 0%, rgba(46,207,136,0) 60%)",
        }}
      />
      {/* feather -> upward liquidity-band motif, subtle hero accent */}
      <FeatherBand
        className="pointer-events-none absolute -right-16 -top-4 hidden h-[440px] w-[560px] opacity-70 lg:block"
      />

      <div className="relative mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="grid items-center gap-12 lg:grid-cols-[minmax(0,1fr)_minmax(0,30rem)]">
          <div>
            <div
              className="mb-5 inline-flex items-center gap-2 rounded-full border px-3 py-1"
              style={{
                borderColor: "rgba(46,207,136,0.28)",
                background: "rgba(46,207,136,0.08)",
              }}
            >
              <span
                className="h-1.5 w-1.5 rounded-full bg-accent"
                style={{ boxShadow: "0 0 8px rgba(46,207,136,0.75)" }}
              />
              <span className="text-micro uppercase tracking-[0.08em] text-accent">
                Launching on Robinhood Chain
              </span>
            </div>

            <h1 className="text-[2.5rem] font-semibold leading-[1.05] tracking-[-0.02em] text-text md:text-[3.5rem]">
              Earn like a{" "}
              <span className="text-accent">market maker</span>. On meme coins and
              stocks.
            </h1>

            <p className="mt-6 max-w-xl text-body text-dim md:text-heading md:leading-8">
              Market makers earn a fee on every trade. FERA opens that seat to
              everyone: deposit, and a vault provides and auto-manages the liquidity
              in the pools you pick, so the trading that usually passes you by pays
              you instead.
            </p>

            <div className="mt-8 flex flex-col gap-3 sm:flex-row">
              <Link href="/app" className={btnPrimary}>
                Launch App
                <span aria-hidden>&rarr;</span>
              </Link>
              <a href="#how" className={btnSecondary}>
                How it works
              </a>
            </div>

            <p className="mt-6 text-caption text-mute">
              Withdraw anytime. On-chain and verifiable. Meme coins now, tokenized
              stocks soon.
            </p>
          </div>

          {/* Immediate visual: the illustrative fee-capture chart. */}
          <div className="lg:pl-2">
            <LpOutcomeChart />
          </div>
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------- how it works ---- */

const STEPS = [
  {
    n: "01",
    t: "Deposit",
    d: "Add two tokens - or just the stablecoin - to a pool you believe in. Your money joins the vault. There's a short window right after you deposit before you can withdraw, to keep out gamers; after that, it's yours to pull anytime.",
  },
  {
    n: "02",
    t: "The vault makes the market",
    d: "It provides the liquidity and actively manages the price range for you. The range auto-adapts: it widens when the market gets wild and tightens when things are calm, so your money stays where the trading actually happens.",
  },
  {
    n: "03",
    t: "You earn the trading fees",
    d: "Every swap pays a fee to whoever provides the liquidity. That's you now. And the fee rises when it's volatile - exactly when being the market maker is riskiest, so you're paid more for the harder moments.",
  },
];

function HowItWorks() {
  return (
    <section id="how" className="scroll-mt-20 border-b border-line">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline overline-gold mb-3">How it works</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          Three steps to the side of the trade that earns.
        </h2>

        <div className="mt-10 grid gap-4 md:grid-cols-3">
          {STEPS.map((s) => (
            <div
              key={s.n}
              className="card-glow rounded-lg border border-line bg-card p-6 shadow-card"
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

/* -------------------------------------------------------------- why it earns -- */

const REASONS = [
  {
    tag: "Auto-adapting range",
    t: "The range moves so you don't have to.",
    d: "Managing a liquidity range by hand is a full-time job. The vault does it: it widens the range through the chaos and tightens it back in the calm, keeping your money in the zone where swaps trade.",
    honest:
      "Managed, not magic. A well-run manual position can still do better - what you get here is that no one has to run it.",
  },
  {
    tag: "Dynamic fee",
    t: "Traders pay more when it's volatile.",
    d: "Volatile, one-sided moves are exactly when providing liquidity is riskiest. FERA's fee climbs right then, so the swings that usually cost providers pay them instead. In calm markets the fee stays low to keep volume flowing.",
    honest:
      "Illustrative shape, not a promise. Quiet markets earn little, and a violent move still carries real risk.",
  },
  {
    tag: "Your side of the trade",
    t: "You're the house, not the player.",
    d: "Trading is a coin flip; making the market is a fee business. FERA puts you on the maker side - collecting a cut of the flow - across the meme coins and, soon, the tokenized stocks people actually trade.",
    honest:
      "Fees are real income, but they're variable and never guaranteed. This isn't a fixed yield.",
  },
];

function WhyItEarns() {
  return (
    <section id="why" className="scroll-mt-20 border-b border-line">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline overline-gold mb-3">Why it earns</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          The moments that usually cost liquidity providers can pay you instead.
        </h2>

        {/* Lead proof: the illustrative dynamic-fee chart. */}
        <div className="mt-10">
          <FeeResponseChart />
        </div>

        <div className="mt-8 grid gap-4 md:grid-cols-3">
          {REASONS.map((x) => (
            <div
              key={x.tag}
              className="card-glow rounded-lg border border-line bg-card p-6 shadow-card"
            >
              <div className="inline-flex rounded-full bg-accent-wash px-2.5 py-1 text-micro uppercase tracking-[0.08em] text-accent">
                {x.tag}
              </div>
              <h3 className="mt-3 text-heading font-semibold tracking-tight text-text">
                {x.t}
              </h3>
              <p className="mt-3 text-body-sm text-dim">{x.d}</p>
              <p className="mt-3 border-l-2 border-line-strong pl-3 text-body-sm text-mute">
                <span className="font-medium text-dim">The honest line:</span>{" "}
                {x.honest}
              </p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------- risk levels ---- */

const LEVELS = [
  {
    name: "Steady",
    tagline: "Wider range, smoother ride.",
    d: "Spreads across a wide range so you stay in position through the swings. A thinner slice of fees, but steadier - built for people who want exposure, not a trading desk.",
    accent: false,
  },
  {
    name: "Active",
    tagline: "Concentrated, higher potential.",
    d: "Sits tight around the current price where most volume trades, so it captures more of the fees. The trade-off is bigger swings in your position when the market moves hard.",
    accent: true,
  },
];

function RiskLevels() {
  return (
    <section id="levels" className="scroll-mt-20 border-b border-line bg-well">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline overline-gold mb-3">Pick your level</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          Two risk levels per pool. You choose the one that fits.
        </h2>
        <p className="mt-3 max-w-2xl text-body text-dim">
          Same pool, same fees to earn - the difference is how much swing you&apos;re
          comfortable with. No lock-ups either way: you can withdraw from either level
          anytime.
        </p>

        <div className="mt-10 grid gap-4 sm:grid-cols-2">
          {LEVELS.map((l) => (
            <div
              key={l.name}
              className="card-glow rounded-lg border border-line bg-card p-6 shadow-card"
            >
              <div className="flex items-center gap-2.5">
                <span
                  className="h-2.5 w-2.5 rounded-full"
                  style={{
                    background: l.accent
                      ? "var(--accent)"
                      : "var(--regime-rwa)",
                  }}
                />
                <span className="text-heading font-semibold text-text">
                  {l.name}
                </span>
              </div>
              <p className="mt-2 text-body font-medium text-dim">{l.tagline}</p>
              <p className="mt-2 text-body-sm text-dim">{l.d}</p>
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
    t: "Managed, not magic.",
    d: "You get an actively managed position, two risk levels, and one-tap simplicity. What you don't get is a claim that it beats a skilled hands-on provider. We'd rather be straight with you.",
  },
  {
    t: "No fixed yield, no promises.",
    d: "Fees are real income, but they rise and fall with real trading. We show you what's earned - we never quote a guaranteed number.",
  },
  {
    t: "Pause protects you.",
    d: "If something looks wrong, deposits and risky moves can be frozen to keep funds safe. Withdrawals are never frozen - your exit is always open.",
  },
  {
    t: "We show our work.",
    d: "Wherever we can, every number we publish is reproducible from public on-chain data. Anything modeled or illustrative is labeled as such, so you always know what you're looking at.",
  },
];

function HonestFraming() {
  return (
    <section
      id="claims"
      className="relative overflow-hidden border-b border-line"
    >
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 h-[340px]"
        style={{
          background:
            "radial-gradient(55% 100% at 50% -10%, rgba(46,207,136,0.06) 0%, rgba(46,207,136,0) 62%)",
        }}
      />
      <div className="relative mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline overline-gold mb-3">Our claim</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          Precise beats loud.
        </h2>
        <p className="mt-3 max-w-2xl text-body text-dim">
          Plenty of liquidity products shipped big promises and still died. Being
          straight with you is the only credible way to do this.
        </p>

        <div className="mt-10 grid gap-4 sm:grid-cols-2">
          {CLAIMS.map((c) => (
            <div
              key={c.t}
              className="card-glow rounded-lg border border-line bg-card p-6 shadow-card"
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

/* ------------------------------------------------------- built on robinhood ---- */

const CHAIN_POINTS = [
  {
    t: "Meme coins first, stocks next",
    d: "FERA launches MEME-first on the pairs people actually trade. Tokenized stocks (RWA) are coming soon - same vault, same idea, applied to stock tokens.",
  },
  {
    t: "Your money stays yours",
    d: "Deposits, withdrawals, and fee accrual run on immutable contracts. The logic that holds your funds can't be swapped out from under you, and withdrawals are never blocked.",
  },
  {
    t: "Reviewed, not rubber-stamped",
    d: "Several internal security review passes. That's not an external audit, and we won't pretend it is - a third-party audit is the bar we hold ourselves to before mainnet.",
  },
];

function RobinhoodChain() {
  return (
    <section id="chain" className="scroll-mt-20 border-b border-line bg-well">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="flex flex-col gap-6 md:flex-row md:items-end md:justify-between">
          <div className="max-w-2xl">
            <div className="overline overline-gold mb-3">Built on Robinhood Chain</div>
            <h2 className="text-display-l font-semibold tracking-tight text-text">
              Where trading got democratized, now market-making does too.
            </h2>
            <p className="mt-3 text-body text-dim">
              FERA is built on Robinhood Chain. We&apos;re not affiliated with
              Robinhood - it&apos;s simply where these pools live.
            </p>
          </div>
        </div>

        <div className="mt-10 grid gap-4 md:grid-cols-3">
          {CHAIN_POINTS.map((x) => (
            <div
              key={x.t}
              className="card-glow rounded-lg border border-line bg-card p-6 shadow-card"
            >
              <div className="text-body font-semibold text-text">{x.t}</div>
              <p className="mt-2 text-body-sm text-dim">{x.d}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------- verifiable ----- */

function Verifiable() {
  return (
    <section
      id="verifiable"
      className="relative overflow-hidden border-b border-line"
    >
      <div className="relative mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="card-glow rounded-lg border border-accent-line bg-card p-8 shadow-glow-accent md:p-10">
          <div className="overline overline-gold mb-3">Verifiable by construction</div>
          <h2 className="max-w-2xl text-title font-semibold tracking-tight text-text md:text-display-l">
            Don&apos;t trust the numbers - check them.
          </h2>
          <p className="mt-3 max-w-2xl text-body text-dim">
            What the vault does is recorded on-chain, in the open. Anyone can recompute
            the fees a pool earned from public data, and the rules that manage your
            money are fixed - they can&apos;t quietly change. The full breakdown lives
            in the docs.
          </p>
          <div className="mt-6">
            <a
              href={DOCS_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-1.5 text-body-sm font-medium text-accent hover:text-accent-strong"
            >
              Read the docs <span aria-hidden>&rarr;</span>
            </a>
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
          Take the market-maker&apos;s seat.
        </h2>
        <p className="mx-auto mt-3 max-w-xl text-body text-dim">
          Deposit into a vault that provides and manages the liquidity for you, earn a
          cut of the trading fees, and withdraw whenever you want.
        </p>
        <div className="mt-8 flex justify-center">
          <Link href="/app" className={btnPrimary}>
            Launch App
            <span aria-hidden>&rarr;</span>
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
      <div className="mx-auto max-w-app px-4 py-14 md:px-6">
        <div className="flex flex-col gap-10 md:flex-row md:items-start md:justify-between">
          <div className="max-w-sm">
            <div className="flex items-center gap-2.5">
              <span className="grid h-8 w-8 place-items-center rounded-lg border border-accent2-line bg-accent2-wash">
                <Logo className="h-5 w-5" />
              </span>
              <Wordmark />
            </div>
            <p className="mt-3 text-body-sm text-dim">
              Democratizing market-making. Built on Robinhood Chain.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-8 sm:grid-cols-3">
            <FooterCol
              title="Learn"
              links={[
                { href: "#how", label: "How it works" },
                { href: "#why", label: "Why it earns" },
                { href: "#levels", label: "Risk levels" },
                { href: "#chain", label: "Robinhood Chain" },
                { href: "#verifiable", label: "Verifiable" },
                { href: DOCS_URL, label: "Docs", external: true },
              ]}
            />
            <FooterCol
              title="Build"
              links={[
                { href: "/app", label: "Launch App" },
                { href: GITHUB_URL, label: "GitHub", external: true },
              ]}
            />
            <FollowUs />
          </div>
        </div>

        <div className="hr my-8" />

        <p className="text-caption text-mute">
          &copy; 2026 FERA. Not affiliated with Robinhood. Nothing here is an offer or
          investment advice.
        </p>
      </div>
    </footer>
  );
}

/** Follow us / contact. The X + Telegram handles are being created by the principal.
 *  Until they exist we render them as clearly not-yet-live rather than as dead links
 *  to "#" (a dead social link is a classic unfinished/scam tell). Swap each span for
 *  a real anchor the moment the handle is live. */
function FollowUs() {
  return (
    <div>
      <div className="overline mb-3">Follow us</div>
      <ul className="space-y-2">
        <li>
          <span className="inline-flex items-center gap-2 text-body-sm text-mute">
            <XIcon />X (Twitter)
            <span className="rounded-full bg-well px-1.5 py-0.5 text-micro uppercase tracking-[0.08em] text-mute">
              soon
            </span>
          </span>
        </li>
        <li>
          <span className="inline-flex items-center gap-2 text-body-sm text-mute">
            <TelegramIcon />
            Telegram
            <span className="rounded-full bg-well px-1.5 py-0.5 text-micro uppercase tracking-[0.08em] text-mute">
              soon
            </span>
          </span>
        </li>
      </ul>
    </div>
  );
}

function XIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width={14}
      height={14}
      fill="currentColor"
      aria-hidden="true"
      className="shrink-0"
    >
      <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24h-6.66l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
    </svg>
  );
}

function TelegramIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width={14}
      height={14}
      fill="currentColor"
      aria-hidden="true"
      className="shrink-0"
    >
      <path d="M21.94 4.9 18.6 20.64c-.25 1.11-.91 1.38-1.85.86l-5.11-3.77-2.47 2.37c-.27.27-.5.5-1.03.5l.37-5.2 9.47-8.56c.41-.36-.09-.57-.64-.23L5.94 13.62l-5.04-1.58c-1.1-.34-1.12-1.1.23-1.63l19.68-7.59c.91-.34 1.71.2 1.13 1.7z" />
    </svg>
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
