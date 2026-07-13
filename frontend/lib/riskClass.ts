import type { RiskClass, Regime } from "./types";

/**
 * User-facing risk-class vocabulary.
 *
 * The vault's internal / on-chain term is "tranche" (MASTER_SPEC §4/§6, VAULT_ARCHITECTURE
 * §2.3). We MUST NOT surface that word in product copy (D-18 - BarnBridge/SEC precedent, ruling
 * routed to legal). The user-facing frame is a **risk profile** with two named choices:
 *
 *  - CORE  → "Active" - core + mid bands: more fee capture, more impermanent loss.
 *  - ANCHOR → "Steady" - tail / wide bands: less fee capture, less impermanent loss.
 *
 * Chosen terms documented in frontend/DESIGN.md. `group` is the collective label.
 * Availability: RWA pools ship both (the "someone LPing NVDA" persona wants Steady); MEME
 * defaults to Active only (D-16 - Anchor-on-memecoins ≈ the rejected v1 product).
 */
export const RISK_CLASS_GROUP_LABEL = "Risk profile";

export const RISK_CLASS_META: Record<
  RiskClass,
  {
    /** the word shown to users - NEVER "tranche". */
    label: string;
    /** on-chain tranche id (0 = Core, 1 = Anchor). */
    tranche: number;
    color: string;
    wash: string;
    /** one-line positioning. */
    tagline: string;
    /** plain-language fee-capture vs IL trade-off. */
    feeCapture: string;
    il: string;
    /** who it's for. */
    persona: string;
    /** where the money sits (band roles), plain language. */
    bands: string;
  }
> = {
  CORE: {
    label: "Active",
    tranche: 0,
    color: "var(--accent)",
    wash: "var(--accent-wash)",
    tagline: "Concentrated near price - more fees, more swings.",
    feeCapture: "Higher fee capture: sits in the deep bands next to spot where most swap volume trades.",
    il: "Higher impermanent loss: because it hugs the current price, a big move moves your position harder.",
    persona: "For yield-seeking capital comfortable with volatility.",
    bands: "Core + mid bands (concentrated at spot).",
  },
  ANCHOR: {
    label: "Steady",
    tranche: 1,
    color: "var(--regime-rwa)",
    wash: "var(--regime-rwa-wash)",
    tagline: "Wide coverage - steadier, thinner fee take.",
    feeCapture: "Lower fee capture: sits in the wide/tail bands, so it earns a thinner slice of swap fees.",
    il: "Lower impermanent loss: the wide range keeps you in-range through crashes and rebounds, so less is realized.",
    persona: "For conservative capital - e.g. someone LPing a stock token who wants exposure, not a trading desk.",
    bands: "Tail / wide bands (always-in-range coverage).",
  },
};

/** The order classes are presented in (Active first - it's the default/primary). */
export const RISK_CLASS_ORDER: RiskClass[] = ["CORE", "ANCHOR"];

/**
 * Which risk classes a pool offers, by regime (D-16). RWA → both; MEME → Core only.
 * A pool's actual `tranches[]` (§8) wins when present; this is the fallback + the
 * "what's available" rule the selector renders against.
 */
export function availableRiskClasses(regime: Regime): RiskClass[] {
  return regime === "RWA" ? ["CORE", "ANCHOR"] : ["CORE"];
}
