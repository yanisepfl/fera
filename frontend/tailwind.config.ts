import type { Config } from "tailwindcss";

/**
 * FERA design tokens - see frontend/DESIGN.md for the full rationale.
 * Colors are wired to CSS variables in app/globals.css so the theme is themeable
 * from one place and stays consistent across Tailwind classes + raw CSS.
 * Aesthetic family: alphix.fi / Canary / Alma / Alps - dark-first, typography-led,
 * greyscale-forward with a single restrained accent (Fera Gold).
 */
const config: Config = {
  darkMode: "class",
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
    "./lib/**/*.{ts,tsx}",
  ],
  theme: {
    // 4px base spatial grid (Tailwind's default already aligns; documented in DESIGN.md).
    extend: {
      colors: {
        // --- Ink scale (surfaces) ---
        canvas: "var(--ink-950)",
        well: "var(--ink-900)",
        card: "var(--ink-875)",
        elevated: "var(--ink-850)",
        surface: "var(--ink-800)",
        raised: "var(--ink-750)",
        hover: "var(--ink-700)",

        // --- Borders ---
        line: "var(--line)",
        "line-strong": "var(--line-strong)",

        // --- Text ---
        text: "var(--text)",
        dim: "var(--text-dim)",
        mute: "var(--text-mute)",

        // --- Accent (single brand accent: Fera Gold) ---
        accent: {
          DEFAULT: "var(--accent)",
          strong: "var(--accent-strong)",
          dim: "var(--accent-dim)",
          wash: "var(--accent-wash)",
          line: "var(--accent-line)",
          fg: "var(--on-accent)",
        },

        // --- Secondary accent (Cove: cool data / analytics accent) ---
        accent2: {
          DEFAULT: "var(--accent2)",
          strong: "var(--accent2-strong)",
          dim: "var(--accent2-dim)",
          wash: "var(--accent2-wash)",
          line: "var(--accent2-line)",
          fg: "var(--on-accent2)",
        },

        // --- Named chart series (both illustrative charts read as one system) ---
        "series-fera": "var(--series-fera)",
        "series-ref": "var(--series-ref)",
        "series-cove": "var(--series-cove)",

        // --- Semantic ---
        pos: "var(--pos)",
        "pos-wash": "var(--pos-wash)",
        neg: "var(--neg)",
        "neg-wash": "var(--neg-wash)",
        warn: "var(--warn)",
        "warn-wash": "var(--warn-wash)",
        danger: {
          DEFAULT: "var(--danger)",
          wash: "var(--danger-wash)",
          line: "var(--danger-line)",
        },

        // --- Regimes ---
        meme: "var(--regime-meme)",
        "meme-wash": "var(--regime-meme-wash)",
        rwa: "var(--regime-rwa)",
        "rwa-wash": "var(--regime-rwa-wash)",
        event: "var(--regime-event)",

        // --- Chart ---
        "chart-grid": "var(--chart-grid)",
        "chart-axis": "var(--chart-axis)",
      },
      fontFamily: {
        sans: ["var(--font-sans)", "ui-sans-serif", "system-ui", "sans-serif"],
        mono: [
          "var(--font-mono)",
          "ui-monospace",
          "SFMono-Regular",
          "Menlo",
          "monospace",
        ],
      },
      fontSize: {
        micro: ["0.6875rem", { lineHeight: "0.875rem", letterSpacing: "0.06em" }], // 11px overline
        caption: ["0.75rem", { lineHeight: "1rem", letterSpacing: "0.01em" }], // 12px
        "body-sm": ["0.8125rem", { lineHeight: "1.125rem" }], // 13px
        body: ["0.9375rem", { lineHeight: "1.375rem" }], // 15px base
        heading: ["1.125rem", { lineHeight: "1.5rem", letterSpacing: "-0.01em" }], // 18px
        title: ["1.375rem", { lineHeight: "1.75rem", letterSpacing: "-0.015em" }], // 22px
        "display-l": ["1.875rem", { lineHeight: "2.25rem", letterSpacing: "-0.02em" }], // 30px
        "display-xl": ["2.5rem", { lineHeight: "2.75rem", letterSpacing: "-0.02em" }], // 40px
        hero: ["3.5rem", { lineHeight: "1", letterSpacing: "-0.01em" }], // 56px live-fee hero
      },
      borderRadius: {
        sm: "6px",
        DEFAULT: "10px",
        md: "10px",
        lg: "14px",
        xl: "18px",
      },
      boxShadow: {
        card: "0 1px 2px rgba(0,0,0,0.4), inset 0 1px 0 rgba(255,255,255,0.02)",
        pop: "0 8px 30px rgba(0,0,0,0.5), 0 2px 8px rgba(0,0,0,0.4)",
        "glow-accent":
          "0 0 0 1px var(--accent-line), 0 10px 34px rgba(231,184,75,0.07)",
        "glow-accent2":
          "0 0 0 1px var(--accent2-line), 0 10px 34px rgba(73,190,224,0.08)",
        "glow-danger":
          "0 0 0 1px var(--danger-line), 0 10px 34px rgba(255,92,77,0.09)",
        "card-hover":
          "0 0 0 1px var(--accent-line), 0 12px 40px rgba(231,184,75,0.10)",
        "card-hover-cove":
          "0 0 0 1px var(--accent2-line), 0 12px 40px rgba(73,190,224,0.10)",
      },
      transitionTimingFunction: {
        out: "cubic-bezier(0.22, 1, 0.36, 1)",
        smooth: "cubic-bezier(0.65, 0, 0.35, 1)",
      },
      transitionDuration: {
        fast: "120ms",
        base: "200ms",
        slow: "320ms",
      },
      keyframes: {
        "pulse-live": {
          "0%, 100%": { opacity: "1", transform: "scale(1)" },
          "50%": { opacity: "0.35", transform: "scale(0.85)" },
        },
        "tick-flash": {
          "0%": { color: "var(--accent)" },
          "100%": { color: "inherit" },
        },
        "fade-up": {
          from: { opacity: "0", transform: "translateY(6px)" },
          to: { opacity: "1", transform: "translateY(0)" },
        },
        shimmer: {
          "100%": { transform: "translateX(100%)" },
        },
      },
      animation: {
        "pulse-live": "pulse-live 1.8s var(--ease-smooth, ease-in-out) infinite",
        "tick-flash": "tick-flash 420ms var(--ease-out, ease-out)",
        "fade-up": "fade-up 240ms var(--ease-out, ease-out) both",
      },
      maxWidth: {
        app: "1160px",
      },
    },
  },
  plugins: [],
};

export default config;
