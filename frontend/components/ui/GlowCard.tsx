import { cn } from "@/lib/cn";

/**
 * GlowCard - the reusable hover-glow card treatment (REDESIGN_PLAN.md §2a).
 *
 * A convenience wrapper that renders the base `Card` surface plus the `.card-glow`
 * utility (defined in globals.css): on hover / focus-within the border brightens to
 * the accent line, a soft accent glow appears, and the card lifts 2px. Under
 * `prefers-reduced-motion` the glow stays (it is information) but the lift is dropped.
 *
 * Surface agents can either:
 *  - drop `.card-glow` (or `card-glow card-glow--cove`) onto an EXISTING card's
 *     className directly - this is the primary path, no import needed; or
 *  - use <GlowCard> for new cards to get the base surface + treatment in one.
 *
 * `tone="cove"` re-tints the glow cyan for data / chart cards.
 */
export function GlowCard({
  className,
  tone = "gold",
  as: Tag = "div",
  ...props
}: React.HTMLAttributes<HTMLElement> & {
  as?: React.ElementType;
  /** "gold" = brand default; "cove" = data / chart cards glow cyan. */
  tone?: "gold" | "cove";
}) {
  return (
    <Tag
      className={cn(
        "rounded-lg border border-line bg-card shadow-card",
        "card-glow",
        tone === "cove" && "card-glow--cove",
        className
      )}
      {...props}
    />
  );
}
