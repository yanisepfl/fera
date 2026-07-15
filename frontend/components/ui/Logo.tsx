import { cn } from "@/lib/cn";

/**
 * FERA brand mark - a single geometric F, condensed and forward-leaning
 * (see /BRAND.md and public/brand/mark.svg for the reference source).
 *
 * Path geometry is copied verbatim from public/brand/mark.svg (5 flat shapes,
 * skewX(-8) group) so it stays crisp at any size. The group fill is
 * `currentColor`, and `color` defaults to `--accent2` (Fera Gold), the retained
 * heritage brand mark - the UI accent is green, but the MARK stays gold
 * (public/brand). Pass `color` to override (e.g. on a solid accent background).
 */
export function Logo({
  className,
  size = 24,
  color = "var(--accent2)",
}: {
  className?: string;
  size?: number | string;
  color?: string;
}) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 100 100"
      width={size}
      height={size}
      fill="none"
      aria-hidden="true"
      className={cn("shrink-0", className)}
      style={{ color }}
    >
      <g transform="skewX(-8)" fill="currentColor">
        <rect x="25" y="14" width="13" height="74" />
        <rect x="38" y="14" width="32" height="13" />
        <polygon points="70,14 70,27 86,20.5" />
        <rect x="38" y="42" width="22" height="12" />
        <polygon points="60,42 60,54 72,48" />
      </g>
    </svg>
  );
}
