import { cn } from "@/lib/cn";

/**
 * FeatherBand - FERA's brand motif: a feather that reads at the same time as an
 * upward-sweeping liquidity band. The feather is the Robin-Hood-archer nod (built
 * on Robinhood Chain); the band is the vault's adaptive price range - tight at the
 * ends, wider through the volatile middle. Used lightly: a hero accent and section
 * dividers. Purely decorative + static (reduced-motion safe), always aria-hidden.
 *
 * Rendered in the brand green (var(--accent)); low opacity so it stays an accent,
 * never a focal point. No blue, ever.
 */
export function FeatherBand({
  className,
  style,
}: {
  className?: string;
  style?: React.CSSProperties;
}) {
  return (
    <svg
      viewBox="0 0 400 300"
      fill="none"
      aria-hidden="true"
      className={cn("select-none", className)}
      style={style}
    >
      <defs>
        <linearGradient id="fb-fill" x1="0" y1="1" x2="1" y2="0">
          <stop offset="0%" stopColor="var(--accent)" stopOpacity="0.02" />
          <stop offset="60%" stopColor="var(--accent)" stopOpacity="0.14" />
          <stop offset="100%" stopColor="var(--accent)" stopOpacity="0.28" />
        </linearGradient>
        <linearGradient id="fb-edge" x1="0" y1="1" x2="1" y2="0">
          <stop offset="0%" stopColor="var(--accent)" stopOpacity="0.15" />
          <stop offset="100%" stopColor="var(--accent)" stopOpacity="0.75" />
        </linearGradient>
      </defs>

      {/* the band: tight at the ends, widening through the volatile middle */}
      <path
        d="M30,258 C150,120 250,92 372,52 C248,170 150,232 30,258 Z"
        fill="url(#fb-fill)"
      />
      <path
        d="M30,258 C150,120 250,92 372,52"
        stroke="url(#fb-edge)"
        strokeWidth="1.5"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
      <path
        d="M30,258 C150,232 248,170 372,52"
        stroke="var(--accent)"
        strokeOpacity="0.28"
        strokeWidth="1"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />

      {/* central spine (the price the band tracks) + feather barbs */}
      <path
        d="M30,258 C160,178 260,132 372,52"
        stroke="var(--accent)"
        strokeOpacity="0.5"
        strokeWidth="1"
        strokeDasharray="2 5"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
      {[
        ["108,214", "150,182"],
        ["150,196", "196,158"],
        ["196,172", "244,138"],
        ["244,150", "292,118"],
        ["292,128", "336,96"],
      ].map(([a, b], i) => (
        <line
          key={i}
          x1={a.split(",")[0]}
          y1={a.split(",")[1]}
          x2={b.split(",")[0]}
          y2={b.split(",")[1]}
          stroke="var(--accent)"
          strokeOpacity="0.32"
          strokeWidth="1"
          strokeLinecap="round"
          vectorEffect="non-scaling-stroke"
        />
      ))}
    </svg>
  );
}

/**
 * BandDivider - a slim section divider echoing the same motif: a hairline that swells
 * into a soft green liquidity-band lens at its center. Full-width, decorative.
 */
export function BandDivider({ className }: { className?: string }) {
  return (
    <div
      aria-hidden
      className={cn("mx-auto w-full max-w-app px-4 md:px-6", className)}
    >
      <svg
        viewBox="0 0 1200 32"
        preserveAspectRatio="none"
        className="h-6 w-full"
        fill="none"
      >
        <defs>
          <linearGradient id="bd-line" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="var(--accent)" stopOpacity="0" />
            <stop offset="50%" stopColor="var(--accent)" stopOpacity="0.55" />
            <stop offset="100%" stopColor="var(--accent)" stopOpacity="0" />
          </linearGradient>
          <radialGradient id="bd-lens" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stopColor="var(--accent)" stopOpacity="0.16" />
            <stop offset="100%" stopColor="var(--accent)" stopOpacity="0" />
          </radialGradient>
        </defs>
        <ellipse cx="600" cy="16" rx="220" ry="14" fill="url(#bd-lens)" />
        <path
          d="M0,16 C420,16 480,7 600,7 C720,7 780,16 1200,16"
          stroke="url(#bd-line)"
          strokeWidth="1"
          vectorEffect="non-scaling-stroke"
        />
        <path
          d="M0,16 C420,16 480,25 600,25 C720,25 780,16 1200,16"
          stroke="url(#bd-line)"
          strokeWidth="1"
          strokeOpacity="0.5"
          vectorEffect="non-scaling-stroke"
        />
      </svg>
    </div>
  );
}
