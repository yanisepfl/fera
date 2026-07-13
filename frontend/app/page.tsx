import Link from "next/link";
import { Logo } from "@/components/ui/Logo";
import { LpOutcomeChart, FeeResponseChart } from "@/components/viz";

/**
 * Marketing landing (front door, "/"). Dark-first, typography-led, one warm gold
 * brand accent + a cool "Cove" data accent (see REDESIGN_PLAN.md). Copy holds the
 * load-bearing honest-framing constraints: the vault is sold as managed +
 * emissions-eligible + simple, NEVER as higher-yield than a self-managed LP. No
 * "tranche" / "dividend" / "guaranteed" / "risk-free". Risk profiles are Steady /
 * Active. Any figure that is not live on-chain data is visibly labeled Modeled /
 * Illustrative (the two viz cards carry their own tag pill + honest caption). No
 * internal tokens in rendered copy. The app itself lives under /app.
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
  { href: "#mechanism", label: "The mechanism" },
  { href: "#claims", label: "What we claim" },
];

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

// Animated gold underline that wipes in on hover (reduced-motion: appears instantly).
const navLink =
  "relative px-1 py-1 text-body-sm font-medium text-mute transition-colors hover:text-text " +
  "after:pointer-events-none after:absolute after:inset-x-0 after:-bottom-0.5 after:h-px " +
  "after:origin-left after:scale-x-0 after:bg-accent after:transition-transform after:duration-fast " +
  "after:ease-out hover:after:scale-x-100 focus-visible:after:scale-x-100";

function MarketingHeader() {
  return (
    <header className="sticky top-0 z-30 border-b border-line bg-well/80 backdrop-blur-md">
      <div className="mx-auto flex h-16 max-w-app items-center gap-8 px-4 md:px-6">
        <BrandLockup />

        <nav className="hidden items-center gap-6 md:flex">
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
        </div>
      </div>
    </header>
  );
}

/** Logo + FERA wordmark, refined lockup: mark sits in a soft gold-wash tile and the
 *  wordmark carries a subtle warm gold gradient so it reads brand, not flat grey. */
function BrandLockup() {
  return (
    <Link href="/" className="group flex shrink-0 items-center gap-2.5">
      <span className="grid h-8 w-8 place-items-center rounded-lg border border-accent-line bg-accent-wash transition-colors duration-fast group-hover:border-accent">
        <Logo className="h-5 w-5" />
      </span>
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
    </Link>
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
      <div className="relative mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="grid items-center gap-12 lg:grid-cols-[minmax(0,1fr)_minmax(0,30rem)]">
          <div>
            <div
              className="mb-5 inline-flex items-center gap-2 rounded-full border px-3 py-1"
              style={{
                borderColor: "rgba(70,192,138,0.28)",
                background: "rgba(70,192,138,0.08)",
              }}
            >
              <span
                className="h-1.5 w-1.5 rounded-full"
                style={{ background: "#46c08a", boxShadow: "0 0 8px rgba(70,192,138,0.75)" }}
              />
              <span
                className="text-micro uppercase tracking-[0.08em]"
                style={{ color: "#8fd9b6" }}
              >
                Live on Robinhood Chain
              </span>
            </div>

            <h1 className="text-[2.5rem] font-semibold leading-[1.05] tracking-[-0.02em] text-text md:text-[3.5rem]">
              Liquidity that gets paid by{" "}
              <span style={{ color: "var(--accent2)" }}>volatility</span>.
            </h1>

            <p className="mt-6 max-w-xl text-body text-dim md:text-heading md:leading-8">
              FERA pools charge volatile, bot-driven trades a higher fee. The flow
              that usually drains liquidity providers earns for ours instead.
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
              On-chain-verifiable, immutable, permissionless. Zero FERA swap fees.
            </p>
          </div>

          {/* Immediate visual punch: the modeled outcome proof, tagged Modeled. */}
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
    t: "Fees that price the flow",
    d: "Our pools set the swap fee live. It climbs with volatility and toxic flow, so the trades that usually drain LPs pay them instead. On-chain and immutable.",
  },
  {
    n: "02",
    t: "Vaults that manage it",
    d: "Deposit and skip position management. Rule-based, zero-discretion strategies inside hardcoded bounds. Pick a profile: Steady or Active.",
  },
  {
    n: "03",
    t: "Yield plus emissions",
    d: "Earn fee yield plus esFERA on your shares. The 10% performance fee applies only to fees you earn, never to principal. Half flows back to FERA stakers.",
  },
];

function HowItWorks() {
  return (
    <section id="how" className="border-b border-line">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline overline-gold mb-3">How it works</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          Smart fees price the risk. Vaults make it effortless. You keep the yield.
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

/* -------------------------------------------------------------- narratives ---- */

// Narratives 2 & 3 render as cards under the featured fee-curve narrative.
const NARRATIVES = [
  {
    tag: "Weekend drift",
    t: "Your position earns the arbitrage instead of feeding it.",
    d: "Tokenized stocks trade all weekend; the real shares don't. Prices drift, then snap back Monday. For a vanilla LP that snap-back is a structural loss. Here it becomes LP income.",
    honest:
      "Steady, but never a promise. A quiet weekend earns little, and a big Monday gap still costs the position.",
  },
  {
    tag: "Toxic flow",
    t: "We don't fight bots. We price them.",
    d: "With no priority-fee auction, wash, volume, and MEV bots are just flow. The more violent and one-sided it gets, the higher the fee they pay. Their flow becomes your fees.",
    honest:
      "We price toxic flow through fees. We don't claim to capture the MEV itself.",
  },
];

function Narratives() {
  return (
    <section id="mechanism" className="border-b border-line">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="overline overline-gold mb-3">The mechanism</div>
        <h2 className="max-w-2xl text-display-l font-semibold tracking-tight text-text">
          The flow that drains most LPs pays yours instead.
        </h2>

        {/* Featured narrative: the fee curve is built to protect the LP. Paired with
            the FeeResponseChart (fee rises with volatility, low in calm). This is
            about protecting / rewarding the LP, distinct from the "Toxic flow" card
            below, which is about who pays. */}
        <div className="mt-10 grid gap-8 lg:grid-cols-2 lg:items-center">
          <div>
            <div className="inline-flex rounded-full bg-accent-wash px-2.5 py-1 text-micro uppercase tracking-[0.08em] text-accent">
              The fee curve
            </div>
            <h3 className="mt-3 text-title font-semibold tracking-tight text-text">
              The fee works hardest when you need it most.
            </h3>
            <p className="mt-4 text-body text-dim">
              High-volatility stretches are when LPs lose the most. FERA&apos;s fee is
              built to rise right then, cushioning the hit in your worst periods. In
              calm markets it stays low to pull the volume that keeps fees flowing.
            </p>
            <p className="mt-3 border-l-2 border-line-strong pl-3 text-body-sm text-mute">
              <span className="font-medium text-dim">The honest line:</span> Modeled
              shape, not a promise. Quiet markets earn little, and a violent one still
              carries real risk.
            </p>
          </div>

          <FeeResponseChart />
        </div>

        <div className="mt-8 grid gap-4 md:grid-cols-2">
          {NARRATIVES.map((x) => (
            <div
              key={x.tag}
              className="card-glow rounded-lg border border-line bg-card p-6 shadow-card md:p-8"
            >
              <div className="inline-flex rounded-full bg-accent-wash px-2.5 py-1 text-micro uppercase tracking-[0.08em] text-accent">
                {x.tag}
              </div>
              <h3 className="mt-3 text-title font-semibold tracking-tight text-text">
                {x.t}
              </h3>
              <p className="mt-3 text-body text-dim">{x.d}</p>
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

/* ----------------------------------------------------------- honest framing ---- */

const CLAIMS = [
  {
    t: "The vault is managed, not magic.",
    d: "You get management, emissions eligibility, simplicity, and a risk profile to pick. What you don't get is a claim that it beats a skilled self-managed LP. We'd rather be straight with you.",
  },
  {
    t: "No fixed yield, no promises, no fine print.",
    d: "Two plain risk profiles: Steady and Active. Staker rewards are a variable share of real protocol activity, never a promise.",
  },
  {
    t: "Emissions can't out-print revenue.",
    d: "Weekly esFERA issuance is capped by protocol revenue and follows real activity. It rewards usage. It isn't a subsidy propping up a number.",
  },
  {
    t: "We try to show our work.",
    d: "Where we can, every number we publish is reproducible from on-chain events. Anything preliminary or modeled is labeled as such, so you always know what you're looking at.",
  },
];

function HonestFraming() {
  return (
    <section id="claims" className="border-b border-line bg-well">
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

/* ------------------------------------------------------------- transparency ---- */

function Transparency() {
  return (
    <section id="transparency" className="border-b border-line">
      <div className="mx-auto max-w-app px-4 py-16 md:px-6 md:py-24">
        <div className="card-glow rounded-lg border border-accent-line bg-card p-8 shadow-glow-accent md:p-10">
          <div className="overline overline-gold mb-3">Verifiable by construction</div>
          <h2 className="max-w-2xl text-title font-semibold tracking-tight text-text md:text-display-l">
            Every fee and every emission, reproducible from on-chain data.
          </h2>
          <p className="mt-3 max-w-2xl text-body text-dim">
            Real revenue and esFERA emissions can be recomputed by anyone from public
            on-chain events. Issuance follows activity, and once an epoch is posted it
            isn&apos;t quietly rewritten. The full revenue and emissions breakdown
            lives in the docs.
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
          LP where every flow pays you.
        </h2>
        <p className="mx-auto mt-3 max-w-xl text-body text-dim">
          Deposit into a managed vault, hold a normal ERC-20 share, and earn fee yield
          plus esFERA on the pools you already believe in.
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
              <span className="grid h-8 w-8 place-items-center rounded-lg border border-accent-line bg-accent-wash">
                <Logo className="h-5 w-5" />
              </span>
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
            </div>
            <p className="mt-3 text-body-sm text-dim">
              LP-first, regime-aware liquidity on Robinhood Chain.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-8 sm:grid-cols-3">
            <FooterCol
              title="Learn"
              links={[
                { href: "#how", label: "How it works" },
                { href: "#mechanism", label: "The mechanism" },
                { href: "#claims", label: "What we claim" },
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
          &copy; 2026 FERA. Nothing here is an offer or investment advice.
        </p>
      </div>
    </footer>
  );
}

/** Follow us / contact. NOTE: X + Telegram handles are being created by the
 *  principal; swap the href="#" placeholders below for the real URLs. */
function FollowUs() {
  const social =
    "inline-flex items-center gap-2 text-body-sm text-dim transition-colors hover:text-text";
  return (
    <div>
      <div className="overline mb-3">Follow us</div>
      <ul className="space-y-2">
        <li>
          {/* TODO: replace with real X (Twitter) URL */}
          <a href="#" className={social}>
            <XIcon />X (Twitter)
          </a>
        </li>
        <li>
          {/* TODO: replace with real Telegram URL */}
          <a href="#" className={social}>
            <TelegramIcon />
            Telegram
          </a>
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
