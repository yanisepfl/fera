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
 * On-chain tranche assignment (VERIFIED against FeraConstants.sol/FeraVault.sol, not assumed):
 * `TIER_STEADY = 0` (±100% wide base — STEADY_BASE_HALF_TICKS) is initialized on tranche 0;
 * `TIER_ACTIVE = 1` (±30% narrow base, 8.1x capital efficiency — ACTIVE_BASE_HALF_TICKS) on
 * tranche 1 (`createBaseLimitPool`'s `_initBaseLimitTranche(id, 0, TIER_STEADY, ...)` /
 * `_initBaseLimitTranche(id, 1, TIER_ACTIVE, ...)`). So CORE/"Active" MUST map to tranche 1
 * and ANCHOR/"Steady" MUST map to tranche 0 - the reverse pairing was a real bug (shipped
 * 2026-07-20, caught before any user relied on it) that would have put a "Steady" depositor
 * into the narrow, higher-IL band and vice versa. Keep `tranche` here as the single source of
 * truth; RISK_CLASS_BY_TRANCHE (types.ts) is its inverse and must stay in sync.
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
    tranche: 1,
    color: "var(--accent)",
    wash: "var(--accent-wash)",
    tagline: "Concentrated near the price - more fees, bigger swings.",
    feeCapture: "Earns more, because it sits right where most trading happens and collects a bigger share of the fees.",
    il: "But bigger swings: it tracks the current price closely, so a large move hits your position harder.",
    persona: "For people chasing yield who are comfortable with volatility.",
    bands: "Concentrated around the current price.",
  },
  ANCHOR: {
    label: "Steady",
    tranche: 0,
    color: "var(--regime-rwa)",
    wash: "var(--regime-rwa-wash)",
    tagline: "Wide range - steadier, thinner fee take.",
    feeCapture: "Earns less, because it spreads across a wide range and collects a thinner slice of the fees.",
    il: "But smaller swings: the wide range keeps you in position through crashes and rebounds, so less is lost to price moves.",
    persona: "For conservative money - e.g. someone holding a stock token who wants exposure, not a trading desk.",
    bands: "Wide range (always-in-position coverage).",
  },
};

/** The order classes are presented in (Active first - it's the default/primary). */
export const RISK_CLASS_ORDER: RiskClass[] = ["CORE", "ANCHOR"];

/**
 * Which risk classes a pool offers, by regime (D-16). RWA → both; MEME → Core only.
 * A pool's actual `tranches[]` (§8) wins when present; this is the fallback + the
 * "what's available" rule the selector renders against.
 *
 * `liveBothTranches`: a REGISTRY pool (config/pools.ts, deployed on Robinhood Chain)
 * always has both tranches initialized on-chain (`createBaseLimitPool` seeds both at
 * pool creation) — so for those, both classes are selectable regardless of regime,
 * even before the indexer has any per-class stats for the newer one (renders "—", see
 * RiskClassSelector). This intentionally supersedes the regime-based D-16 default,
 * which was about NOT simulating a class that doesn't exist yet — once it verifiably
 * exists on-chain, hiding it would be the dishonest choice. Fixture/mock MEME pools
 * (no `live` match) keep the original D-16 single-class behavior unchanged.
 */
export function availableRiskClasses(regime: Regime, liveBothTranches?: boolean): RiskClass[] {
  if (liveBothTranches) return ["CORE", "ANCHOR"];
  return regime === "RWA" ? ["CORE", "ANCHOR"] : ["CORE"];
}
