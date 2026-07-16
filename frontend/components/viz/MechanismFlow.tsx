/**
 * MechanismFlow - a small inline illustration of the money loop, in the same
 * family as FeatherBand and the illustrative charts: pure self-contained SVG,
 * CSS-var colors (theme-aware), no external assets, reduced-motion safe (static).
 *
 * The story, left to right: YOU deposit -> the VAULT holds the adaptive range
 * (the band motif: tight at the ends, wide through the volatile middle) while
 * traders swap through it -> the FEES arc back to you in the green action/positive
 * color. Gold stays the brand/mechanism color; green is money coming back.
 *
 * Meaningful (not decorative), so it ships role="img" + a plain-language label.
 */
export function MechanismFlow({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 460 240"
      fill="none"
      role="img"
      aria-label="Flow diagram: you deposit into the vault; the vault provides liquidity across an adaptive price range that traders swap through; the trading fees flow back to you."
      className={className}
    >
      <defs>
        <linearGradient id="mf-band" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="var(--accent)" stopOpacity="0.2" />
          <stop offset="100%" stopColor="var(--accent)" stopOpacity="0.04" />
        </linearGradient>
        <linearGradient id="mf-deposit" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0%" stopColor="var(--text-mute)" stopOpacity="0.5" />
          <stop offset="100%" stopColor="var(--accent)" stopOpacity="0.8" />
        </linearGradient>
      </defs>

      {/* -------- left node: you -------- */}
      <circle
        cx="52"
        cy="118"
        r="17"
        fill="var(--accent-wash)"
        stroke="var(--accent-line)"
        strokeWidth="1"
      />
      {/* a coin about to leave the node */}
      <circle cx="52" cy="118" r="5.5" fill="var(--accent)" fillOpacity="0.85" />
      <text
        x="52"
        y="158"
        textAnchor="middle"
        fontSize="10"
        letterSpacing="0.08em"
        fill="var(--text-mute)"
        className="font-sans"
        style={{ textTransform: "uppercase" }}
      >
        You deposit
      </text>

      {/* deposit arrow: you -> vault */}
      <path
        d="M74,118 C92,118 100,116 116,114"
        stroke="url(#mf-deposit)"
        strokeWidth="1.5"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
      <path d="M112,109.2 L120,113.6 L111.4,116.8 Z" fill="var(--accent)" fillOpacity="0.8" />

      {/* -------- center: the vault's adaptive band (feather-band motif) -------- */}
      {/* band: tight at the ends, wide through the volatile middle */}
      <path
        d="M128,114 C180,74 288,74 356,110 C290,152 182,152 128,114 Z"
        fill="url(#mf-band)"
      />
      <path
        d="M128,114 C180,74 288,74 356,110"
        stroke="var(--accent)"
        strokeOpacity="0.6"
        strokeWidth="1.25"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
      <path
        d="M128,114 C182,152 290,152 356,110"
        stroke="var(--accent)"
        strokeOpacity="0.3"
        strokeWidth="1"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
      {/* the price the band tracks (dashed spine) */}
      <path
        d="M128,114 C170,106 208,124 244,110 C280,97 322,118 356,110"
        stroke="var(--accent)"
        strokeOpacity="0.55"
        strokeWidth="1"
        strokeDasharray="2 5"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
      {/* traders swapping through the band (small neutral crossings) */}
      {[
        ["186,86", "178,138"],
        ["242,80", "250,136"],
        ["300,84", "292,134"],
      ].map(([a, b], i) => {
        const [x1, y1] = a.split(",").map(Number);
        const [x2, y2] = b.split(",").map(Number);
        return (
          <g key={i} stroke="var(--text-mute)" strokeOpacity="0.45">
            <line x1={x1} y1={y1} x2={x2} y2={y2} strokeWidth="1" strokeDasharray="1 3" />
            <circle cx={x2} cy={y2} r="1.6" fill="var(--text-mute)" fillOpacity="0.5" stroke="none" />
          </g>
        );
      })}
      <text
        x="242"
        y="52"
        textAnchor="middle"
        fontSize="10"
        letterSpacing="0.08em"
        fill="var(--accent)"
        className="font-sans"
        style={{ textTransform: "uppercase" }}
      >
        The vault runs the range
      </text>
      <text
        x="242"
        y="66"
        textAnchor="middle"
        fontSize="9"
        letterSpacing="0.04em"
        fill="var(--text-mute)"
        className="font-sans"
      >
        traders swap through it
      </text>

      {/* -------- fees flow back: green return arc, band -> you -------- */}
      <path
        d="M356,112 C408,116 424,150 400,178 C360,216 130,214 64,144"
        stroke="var(--accent2)"
        strokeOpacity="0.65"
        strokeWidth="1.5"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
      {/* coins riding the arc home */}
      <circle cx="336" cy="196" r="3" fill="var(--accent2)" fillOpacity="0.8" />
      <circle cx="216" cy="205" r="2.4" fill="var(--accent2)" fillOpacity="0.6" />
      <circle cx="120" cy="182" r="2" fill="var(--accent2)" fillOpacity="0.45" />
      {/* arrowhead into the YOU node */}
      <path d="M70.5,152.5 L60,139.5 L74.5,142.5 Z" fill="var(--accent2)" fillOpacity="0.8" />
      <text
        x="232"
        y="232"
        textAnchor="middle"
        fontSize="10"
        letterSpacing="0.08em"
        fill="var(--accent2)"
        className="font-sans"
        style={{ textTransform: "uppercase" }}
      >
        Fees flow back to you
      </text>
    </svg>
  );
}
