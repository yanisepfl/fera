import Link from "next/link";
import { FeatherBand, BandDivider } from "@/components/ui/FeatherBand";
import { LpOutcomeChart, FeeResponseChart, MechanismFlow } from "@/components/viz";
import { MarketingMobileNav } from "@/components/layout/MarketingMobileNav";
import {
  SiteHeader,
  BrandLockup,
  navLinkClass,
} from "@/components/layout/SiteHeader";

/**
 * Marketing landing (front door, "/"). Concept: FERA democratizes market-making.
 * Robinhood democratized trading; FERA opens the market-maker seat - the side that
 * earns the fees - to everyone.
 *
 * COLOR SYSTEM: gold (--accent) is the brand accent - titles + title highlights,
 * eyebrows, card glows, the mark/motif. Green (--accent2) is reserved for ACTIONS
 * (CTAs) and live/positive signals; positive numbers use --pos. No blue, anywhere.
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
// Actions are green (accent2); gold is never a button.
const btnBase =
  "inline-flex items-center justify-center font-medium whitespace-nowrap select-none transition-[background,color,border,box-shadow] duration-fast ease-out rounded-lg h-12 px-6 text-body gap-2";
const btnPrimary = `${btnBase} bg-accent2 text-accent2-fg hover:bg-accent2-strong active:bg-accent2-dim shadow-glow-accent2`;
const btnSecondary = `${btnBase} bg-surface text-text border border-line hover:border-line-strong hover:bg-raised`;

// Section anchors, shared by the header nav + footer so nothing is orphaned.
const SECTIONS = [
  { href: "#how", label: "How it works" },
  { href: "#why", label: "Why it earns" },
  { href: "#levels", label: "Risk levels" },
  { href: "#open", label: "Open to anyone" },
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
        <TrustMechanism />
        <OpenToAnyone />
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

/**
 * Marketing header on the shared SiteHeader shell (same chrome as the app's
 * TopNav). Full nav only from lg: five links plus Docs don't fit an md viewport
 * without overflowing, so md tablets get the burger too.
 */
function MarketingHeader() {
  return (
    <SiteHeader
      brandHref="/"
      nav={
        <nav className="hidden min-w-0 flex-1 items-center justify-center gap-6 lg:flex">
          {SECTIONS.map((n) => (
            <a key={n.href} href={n.href} className={navLinkClass}>
              {n.label}
            </a>
          ))}
          <a
            href={DOCS_URL}
            target="_blank"
            rel="noopener noreferrer"
            className={navLinkClass}
          >
            Docs
          </a>
        </nav>
      }
      right={
        <>
          <Link
            href="/app"
            className="inline-flex h-9 items-center justify-center gap-1.5 whitespace-nowrap rounded-lg bg-accent2 px-3 text-body-sm font-medium text-accent2-fg shadow-glow-accent2 transition-colors duration-fast hover:bg-accent2-strong active:bg-accent2-dim sm:px-4"
          >
            Launch App
          </Link>
          <MarketingMobileNav sections={SECTIONS} docsUrl={DOCS_URL} />
        </>
      }
    />
  );
}

/* -------------------------------------------------------------------- hero ---- */

function Hero() {
  return (
    <section className="relative overflow-hidden border-b border-line">
      {/* soft top-crown glow (gold) - the lifted premium-dark trait, reduced-motion-safe */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 h-[420px]"
        style={{
          background:
            "radial-gradient(60% 100% at 50% -10%, rgba(231,184,75,0.10) 0%, rgba(231,184,75,0) 60%)",
        }}
      />
      {/* feather -> upward liquidity-band motif, subtle hero accent. xl-only: below
          that there's no free corner for it, so it hides instead of colliding. */}
      <FeatherBand
        className="pointer-events-none absolute -right-16 -top-4 hidden h-[440px] w-[560px] opacity-70 xl:block"
      />

      <div className="relative mx-auto max-w-app px-4 py-14 md:px-6 md:py-24">
        {/* Stacks below lg (text, then chart); the chart column narrows at lg and
            relaxes at xl so the headline never gets crushed at in-between widths. */}
        <div className="grid items-center gap-10 md:gap-12 lg:grid-cols-[minmax(0,1fr)_minmax(0,24rem)] xl:grid-cols-[minmax(0,1fr)_minmax(0,30rem)]">
          <div className="min-w-0">
            <div className="mb-5 inline-flex max-w-full items-center gap-2 rounded-full border border-accent2-line bg-accent2-wash px-3 py-1">
              <span
                className="h-1.5 w-1.5 shrink-0 rounded-full bg-accent2"
                style={{ boxShadow: "0 0 8px rgba(46,207,136,0.75)" }}
              />
              <span className="min-w-0 text-micro uppercase tracking-[0.08em] text-accent2">
                Launching on Robinhood Chain
              </span>
            </div>

            {/* Fluid headline: 34px floor on phones -> 56px cap, no fixed md jump,
                so narrow and in-between windows never overflow or crush. */}
            <h1 className="text-[clamp(2.125rem,1.1rem+3.4vw,3.5rem)] font-semibold leading-[1.05] tracking-[-0.02em] text-text">
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

            <div className="mt-8 flex flex-col gap-3 sm:flex-row sm:flex-wrap">
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
          <div className="min-w-0 lg:pl-2">
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
            "radial-gradient(55% 100% at 50% -10%, rgba(231,184,75,0.06) 0%, rgba(231,184,75,0) 62%)",
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

/* ---------------------------------------------------------- the mechanism ---- */

function TrustMechanism() {
  return (
    <section id="mechanism" className="scroll-mt-20 border-b border-line bg-well">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="grid items-center gap-10 md:grid-cols-[minmax(0,1fr)_minmax(0,26rem)]">
          <div className="min-w-0">
            <div className="overline overline-gold mb-3">The mechanism</div>
            <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
              Trust the mechanism, not our word for it.
            </h2>
            <p className="mt-3 max-w-2xl text-body text-dim">
              The strongest thing we can offer isn&apos;t a promise. It&apos;s a
              loop you can check: your deposit provides the liquidity, the vault
              keeps it where the trading happens, and every swap that crosses it
              pays a fee back to you. The rules are fixed, in the open, and
              can&apos;t quietly change.
            </p>
          </div>

          {/* the loop, drawn: deposit -> vault runs the range -> fees flow back */}
          <div className="min-w-0">
            <MechanismFlow className="h-auto w-full max-w-md md:ml-auto" />
          </div>
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------ open to anyone -- */

// The permissionless story. HONESTY: pool creation + direct LP are genuinely
// ungated; the managed vault runs only on curated pools - say both plainly.
const OPEN_POINTS = [
  {
    t: "Anyone can open a pool",
    d: "Pool creation is permissionless. Any token, any pair - launch it straight through the protocol. No listing desk, no approval queue, no one to ask.",
  },
  {
    t: "LP with or without us",
    d: "Every pool is open liquidity. Provide directly and run your own range if you want - the vault holds no monopoly and gets no special treatment.",
  },
  {
    t: "Curated where it counts",
    d: "The managed vault only runs on pools we curate, so one-tap depositors aren't dropped into just anything. Open underneath, a safer default on top.",
  },
];

function OpenToAnyone() {
  return (
    <section id="open" className="scroll-mt-20 border-b border-line">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline overline-gold mb-3">Open to anyone</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          No gatekeepers. Anyone can make a market.
        </h2>
        <p className="mt-3 max-w-2xl text-body text-dim">
          FERA is a protocol, not a walled garden. The doors - creating pools,
          providing liquidity - are open to everyone, not just our vault.
        </p>

        <div className="mt-10 grid gap-4 md:grid-cols-3">
          {OPEN_POINTS.map((x) => (
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

        <div className="mt-10 grid gap-4 sm:grid-cols-2">
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
        {/* Same treatment as every other card: quiet at rest, glow on hover only. */}
        <div className="card-glow rounded-lg border border-line bg-card p-8 shadow-card md:p-10">
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
            <BrandLockup />
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
                { href: "#mechanism", label: "The mechanism" },
                { href: "#open", label: "Open to anyone" },
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

        <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <p className="text-caption text-mute">
            &copy; 2026 FERA. Not affiliated with Robinhood. Nothing here is an offer or
            investment advice.
          </p>
          <nav className="flex flex-wrap items-center gap-x-4 gap-y-1 text-caption">
            <Link href="/legal/terms" className="text-mute transition-colors hover:text-text">
              Terms
            </Link>
            <Link href="/legal/privacy" className="text-mute transition-colors hover:text-text">
              Privacy
            </Link>
            <Link href="/legal/risk" className="text-mute transition-colors hover:text-text">
              Risk Disclosure
            </Link>
          </nav>
        </div>
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
