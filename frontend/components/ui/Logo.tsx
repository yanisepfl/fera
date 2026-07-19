import { cn } from "@/lib/cn";

/**
 * FERA brand mark - a CLAW: three tapering slashes sweeping up and to the right
 * (Fera = Latin/Portuguese for "wild beast / feral"). See public/brand/mark.svg
 * for the reference source.
 *
 * Path geometry is copied verbatim from public/brand/mark.svg (3 claw strokes) so
 * it stays crisp at any size. The group fill is `currentColor`, and `color`
 * defaults to `--accent` (Fera Green), the brand accent. Pass `color` to override
 * (e.g. on a solid accent background).
 */
export function Logo({
  className,
  size = 24,
  color = "var(--accent)",
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
      <g fill="currentColor">
        <path d="M20 80 C24 62 30 47 38 36 C35 51 31 67 28 84 Z" />
        <path d="M39 83 C44 61 51 43 61 28 C56 47 50 67 46 87 Z" />
        <path d="M59 85 C65 59 73 39 85 20 C78 44 70 67 66 89 Z" />
      </g>
    </svg>
  );
}
