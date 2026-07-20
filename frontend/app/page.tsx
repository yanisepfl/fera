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
 * Marketing landing (front door, "/"). Concept: meme coins never sit still, and FERA turns
 * that nonstop movement into a yield on the coins you already hold. Lead with the outcome
 * (the volatility works for you); the fee mechanic is the plain "how", never the pitch.
 *
 * COLOR SYSTEM: green (--accent) is the brand accent: titles and title highlights, eyebrows,
 * card glows, the mark/motif. The deeper green (--accent2) carries ACTIONS (CTAs) and
 * live/positive signals; positive numbers use --pos. Gold (--gold) survives only as a rare
 * reward/earn spark. No blue, anywhere.
 *
 * HONESTY (load-bearing): the vault is sold as managed and simple, NEVER as higher-yield than
 * a skilled self-managed LP. No "guaranteed" / "risk-free" / fixed yield. Risk levels are
 * Steady / Active (never "tranche"). Any figure that isn't live on-chain data is visibly
 * illustrative (the two viz cards carry their own honest framing). No internal jargon (no
 * "toxic flow", "regime", "TWAP", "LVR") in rendered copy. The app itself lives under /app;
 * nothing is live yet (see the "Launching on Robinhood Chain" badge).
 *
 * STYLE: no em-dashes in rendered copy (the principal finds them AI-tell). Use periods,
 * commas, or parentheses.
 */

const DOCS_URL = "https://fera-3.gitbook.io/fera/";
const GITHUB_URL = "https://github.com/yanisepfl/fera";

// Anchor-styled links that reuse the Button visual language without a client handler.
// Actions are green (accent2); the brand green (accent) and the gold spark are never buttons.
const btnBase =
  "inline-flex items-center justify-center font-medium whitespace-nowrap select-none transition-[background,color,border,box-shadow] duration-fast ease-out rounded-lg h-12 px-6 text-body gap-2";
const btnPrimary = `${btnBase} bg-accent2 text-accent2-fg hover:bg-accent2-strong active:bg-accent2-dim shadow-glow-accent2`;
const btnSecondary = `${btnBase} bg-surface text-text border border-line hover:border-line-strong hover:bg-raised`;

// Section anchors, shared by the header nav + footer so nothing is orphaned.
const SECTIONS = [
  { href: "#how", label: "How it works" },
  { href: "#why", label: "Why it earns" },
  { href: "#levels", label: "Risk levels" },
  { href: "#faq", label: "FAQ" },
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
        <Faq />
        <BandDivider className="py-6" />
        <CtaBand />
      </main>

      <MarketingFooter />
    </div>
  );
}

/* ------------------------------------------------------------------ header ---- */

/**
 * Marketing header on the shared SiteHeader shell (same chrome as the app's TopNav).
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
      {/* soft top-crown glow (green), the lifted premium-dark trait, reduced-motion-safe */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 h-[420px]"
        style={{
          background:
            "radial-gradient(60% 100% at 50% -10%, rgba(47,224,138,0.10) 0%, rgba(47,224,138,0) 60%)",
        }}
      />
      {/* feather motif, subtle hero accent. xl-only: below that there's no free corner. */}
      <FeatherBand className="pointer-events-none absolute -right-16 -top-4 hidden h-[440px] w-[560px] opacity-70 xl:block" />

      <div className="relative mx-auto max-w-app px-4 py-14 md:px-6 md:py-24">
        <div className="grid items-center gap-10 md:gap-12 lg:grid-cols-[minmax(0,1fr)_minmax(0,24rem)] xl:grid-cols-[minmax(0,1fr)_minmax(0,30rem)]">
          <div className="min-w-0">
            <div className="mb-5 inline-flex max-w-full items-center gap-2 rounded-full border border-accent2-line bg-accent2-wash px-3 py-1">
              <span
                className="h-1.5 w-1.5 shrink-0 rounded-full bg-accent2"
                style={{ boxShadow: "0 0 8px rgba(47,224,138,0.75)" }}
              />
              <span className="min-w-0 text-micro uppercase tracking-[0.08em] text-accent2">
                Launching on Robinhood Chain
              </span>
            </div>

            <h1 className="text-[clamp(2.125rem,1.1rem+3.4vw,3.5rem)] font-semibold leading-[1.05] tracking-[-0.02em] text-text">
              Degen energy.{" "}
              <span className="text-accent">Grown-up returns.</span>
            </h1>

            <p className="mt-6 max-w-xl text-body text-dim md:text-heading md:leading-8">
              Meme coins never sit still, and now the movement pays you. A managed-liquidity
              vault turns the volatility that wrecks most LPs into your fee income. You still
              hold the coins you believe in, and the swings finally work for you.
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
              Not a launchpad. The layer that makes the launches liquid. On-chain and
              verifiable, meme coins now, tokenized stocks soon.
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
    d: "Add two tokens, or just the stablecoin, to a pool you believe in. Your money joins the vault and starts earning from the very next trade.",
  },
  {
    n: "02",
    t: "The vault does the work",
    d: "It provides the liquidity and actively manages the price range for you. The range auto-adapts: wider when the market gets wild, tighter when things are calm, so your money stays where the trading actually happens.",
  },
  {
    n: "03",
    t: "The fees flow to you",
    d: "Every swap pays a fee to whoever provides the liquidity. That's you now. And the fee climbs when it's volatile, exactly when providing liquidity is riskiest, so you're paid more for the harder moments.",
  },
];

function HowItWorks() {
  return (
    <section id="how" className="scroll-mt-20 border-b border-line">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline overline-gold mb-3">How it works</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          Three steps, and the vault takes it from there.
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

        {/* The same loop, drawn: deposit, the vault runs the range, the fees flow back. */}
        <div className="mt-10 rounded-lg border border-line bg-card/60 p-6 shadow-card md:p-8">
          <div className="mx-auto flex max-w-2xl flex-col items-center gap-4">
            <p className="text-center text-body-sm text-mute">
              The whole loop, start to finish. Your deposit provides the liquidity, the vault
              keeps it where the trading happens, and every swap that crosses it pays a fee
              back to you.
            </p>
            <MechanismFlow className="h-auto w-full max-w-md" />
          </div>
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
    d: "Managing a liquidity range by hand is a full-time job. The vault does it, widening through the chaos and tightening back in the calm, keeping your money in the zone where swaps actually trade.",
    honest:
      "Managed, not magic. A well-run manual position can still do better. What you get here is that no one has to run it.",
  },
  {
    tag: "Dynamic fee",
    t: "Traders pay more when it's volatile.",
    d: "Volatile, one-sided moves are exactly when providing liquidity is riskiest. FERA's fee climbs right then, so the swings that usually cost providers pay them instead. In calm markets the fee stays low to keep volume flowing.",
    honest:
      "Illustrative shape, not a promise. Quiet markets earn little, and a violent move still carries real risk.",
  },
  {
    tag: "Your coins, plus yield",
    t: "Keep the coins. Earn on the trading.",
    d: "You still hold what you deposited, with all of its upside. FERA adds a second stream on top: the fee from every swap that trades against your liquidity. The coins you already believe in, now doing two jobs at once.",
    honest:
      "Fees are real income, but variable and never guaranteed. And when prices move hard, providing liquidity carries its own risk.",
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
                <span className="font-medium text-dim">The honest line:</span> {x.honest}
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
    d: "Spreads across a wide range so you stay in position through the swings. A thinner slice of fees, but steadier, built for people who want exposure, not a trading desk.",
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
        <div className="overline overline-gold mb-3">Risk levels</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          Choose the risk level that fits your profile.
        </h2>
        <p className="mt-3 max-w-2xl text-body text-dim">
          Same pool, same fees to earn. The difference is how much swing you&apos;re
          comfortable with. Neither level locks you in longer than the other.
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
                    background: l.accent ? "var(--accent)" : "var(--regime-rwa)",
                  }}
                />
                <span className="text-heading font-semibold text-text">{l.name}</span>
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

/* ------------------------------------------------------------------- faq ------ */

// One FAQ absorbs what used to be four thin sections (Our claim, Open to anyone,
// Robinhood Chain, Verifiable). Straight answers, honest framing, native <details>
// accordion so it stays server-rendered with no client JS.
const FAQS = [
  {
    q: "Is FERA permissionless?",
    a: "Yes. Anyone can open a pool, any token or pair, with no listing desk and no approval queue. Every pool is open liquidity too: you can provide directly and run your own range. The managed vault gets no special treatment, it simply runs on the pools we curate so one-tap depositors aren't dropped into anything.",
  },
  {
    q: "Is it custodial? Can anyone touch my funds?",
    a: "No. FERA is non-custodial. Deposits, withdrawals, and fee accrual run on immutable contracts. Only you can move your funds, and the logic that holds them cannot be swapped out from under you.",
  },
  {
    q: "Can I verify what the vault does?",
    a: "Everything is on-chain and in the open. Anyone can recompute the fees a pool earned from public data, and the rules that manage your money are fixed. Transparent and immutable, by construction.",
  },
  {
    q: "Does FERA beat managing my own liquidity?",
    a: "We don't claim to. You get an actively managed position, two risk levels, and one-tap simplicity. A skilled hands-on provider can still do better. What FERA gives you is that no one has to run it. We'd rather be straight with you.",
  },
  {
    q: "Is the yield fixed or guaranteed?",
    a: "No. Fees are real income, but they rise and fall with real trading. We show you what's earned and never quote a guaranteed number. This is not a fixed yield.",
  },
  {
    q: "What happens when I withdraw?",
    a: "You withdraw straight from the pool, in-kind: your pro-rata share of the actual tokens, with no pricing and nothing to sell. The only wait is a short one-time hold right after you deposit (a standard anti-gaming guard); once it passes, your exit is always open.",
  },
  {
    q: "What is Robinhood Chain? Are you affiliated with Robinhood?",
    a: "Robinhood Chain is simply where these pools live. FERA is not affiliated with Robinhood. We launch meme-coin-first, with tokenized stocks coming next: the same vault, the same idea, applied to the stocks people actually trade.",
  },
];

function Faq() {
  return (
    <section
      id="faq"
      className="relative scroll-mt-20 overflow-hidden border-b border-line"
    >
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 h-[340px]"
        style={{
          background:
            "radial-gradient(55% 100% at 50% -10%, rgba(47,224,138,0.06) 0%, rgba(47,224,138,0) 62%)",
        }}
      />
      <div className="relative mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline overline-gold mb-3">FAQ</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          The questions worth asking.
        </h2>
        <p className="mt-3 max-w-2xl text-body text-dim">
          Straight answers on how FERA works, what it doesn&apos;t promise, and who can use it.
        </p>

        <div className="mx-auto mt-10 grid max-w-3xl gap-3">
          {FAQS.map((f) => (
            <details
              key={f.q}
              className="card-glow group rounded-lg border border-line bg-card p-5 shadow-card"
            >
              <summary className="flex cursor-pointer list-none items-center justify-between gap-4 text-body font-semibold text-text [&::-webkit-details-marker]:hidden">
                {f.q}
                <span
                  aria-hidden
                  className="grid h-6 w-6 shrink-0 place-items-center rounded-full border border-line-strong text-accent transition-transform duration-fast group-open:rotate-45"
                >
                  +
                </span>
              </summary>
              <p className="mt-3 text-body-sm text-dim">{f.a}</p>
            </details>
          ))}
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
          Put the volatility to work.
        </h2>
        <p className="mx-auto mt-3 max-w-xl text-body text-dim">
          Deposit the meme coins you already hold into a vault that earns the trading fees for
          you. The movement does the rest.
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
              Where meme coin movement pays you. Built on Robinhood Chain.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-8 sm:grid-cols-3">
            <FooterCol
              title="Learn"
              links={[
                { href: "#how", label: "How it works" },
                { href: "#why", label: "Why it earns" },
                { href: "#levels", label: "Risk levels" },
                { href: "#faq", label: "FAQ" },
                { href: DOCS_URL, label: "Docs", external: true },
              ]}
            />
            <FooterCol
              title="Build"
              links={[
                { href: "/app", label: "Launch App" },
                {
                  href: GITHUB_URL,
                  label: "GitHub",
                  external: true,
                  icon: <GitHubIcon />,
                },
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

const X_URL = "https://x.com/feradotfun";
const TELEGRAM_URL = "https://t.me/feradotfun";

/** Follow us / contact. X + Telegram are live (@feradotfun); Discord exists but isn't
 *  ready to send people to yet, so it stays in the same "clearly not-yet-live" span
 *  treatment the other two used before their handles existed — never a dead "#" link
 *  (a classic unfinished/scam tell). Swap the span for a real anchor once it's ready. */
function FollowUs() {
  return (
    <div>
      <div className="overline mb-3">Follow us</div>
      <ul className="space-y-2">
        <li>
          <a
            href={X_URL}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 text-body-sm text-dim transition-colors hover:text-text"
          >
            <XIcon />X (Twitter)
          </a>
        </li>
        <li>
          <a
            href={TELEGRAM_URL}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 text-body-sm text-dim transition-colors hover:text-text"
          >
            <TelegramIcon />
            Telegram
          </a>
        </li>
        <li>
          <span className="inline-flex items-center gap-2 text-body-sm text-mute">
            <DiscordIcon />
            Discord
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

function DiscordIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width={14}
      height={14}
      fill="currentColor"
      aria-hidden="true"
      className="shrink-0"
    >
      <path d="M20.317 4.37a19.79 19.79 0 0 0-4.885-1.515.07.07 0 0 0-.075.035c-.211.375-.444.865-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.617-1.25.077.077 0 0 0-.075-.035A19.74 19.74 0 0 0 3.68 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 0 0 .031.057 19.9 19.9 0 0 0 5.993 3.03.078.078 0 0 0 .084-.028 14.2 14.2 0 0 0 1.226-1.994.076.076 0 0 0-.041-.106 13.1 13.1 0 0 1-1.872-.892.077.077 0 0 1-.008-.128q.189-.142.365-.29a.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.061 0a.073.073 0 0 1 .078.01q.176.148.365.29a.077.077 0 0 1-.006.129 12.3 12.3 0 0 1-1.873.891.076.076 0 0 0-.04.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.029 19.84 19.84 0 0 0 6.002-3.03.077.077 0 0 0 .032-.055c.5-5.177-.838-9.673-3.549-13.66a.06.06 0 0 0-.031-.028M8.02 15.33c-1.183 0-2.157-1.086-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.211 0 2.176 1.096 2.157 2.42 0 1.332-.955 2.418-2.157 2.418m7.975 0c-1.183 0-2.157-1.086-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.332-.946 2.418-2.157 2.418" />
    </svg>
  );
}

function GitHubIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width={14}
      height={14}
      fill="currentColor"
      aria-hidden="true"
      className="shrink-0"
    >
      <path d="M12 .5C5.37.5 0 5.87 0 12.5c0 5.3 3.44 9.8 8.21 11.39.6.11.82-.26.82-.58 0-.29-.01-1.04-.02-2.05-3.34.73-4.04-1.61-4.04-1.61-.55-1.39-1.34-1.76-1.34-1.76-1.09-.75.08-.73.08-.73 1.2.09 1.84 1.24 1.84 1.24 1.07 1.83 2.81 1.3 3.5.99.11-.78.42-1.3.76-1.6-2.67-.3-5.47-1.34-5.47-5.95 0-1.31.47-2.39 1.24-3.23-.13-.3-.54-1.53.12-3.18 0 0 1.01-.32 3.3 1.23a11.5 11.5 0 0 1 6 0c2.29-1.55 3.3-1.23 3.3-1.23.66 1.65.25 2.88.12 3.18.77.84 1.24 1.92 1.24 3.23 0 4.62-2.81 5.64-5.49 5.94.43.37.82 1.1.82 2.22 0 1.6-.02 2.89-.02 3.29 0 .32.22.7.83.58A12.01 12.01 0 0 0 24 12.5C24 5.87 18.63.5 12 .5z" />
    </svg>
  );
}

function FooterCol({
  title,
  links,
}: {
  title: string;
  links: {
    href: string;
    label: string;
    external?: boolean;
    icon?: React.ReactNode;
  }[];
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
                className="inline-flex items-center gap-2 text-body-sm text-dim transition-colors hover:text-text"
              >
                {l.icon}
                {l.label}
              </a>
            ) : (
              <Link
                href={l.href}
                className="inline-flex items-center gap-2 text-body-sm text-dim transition-colors hover:text-text"
              >
                {l.icon}
                {l.label}
              </Link>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}
