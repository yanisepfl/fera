import { cn } from "@/lib/cn";

/** Pulsing "LIVE" indicator. Pulse halts under prefers-reduced-motion (globals.css). */
export function LiveDot({
  label = "LIVE",
  color = "var(--accent)",
  className,
}: {
  label?: string | null;
  color?: string;
  className?: string;
}) {
  return (
    <span className={cn("inline-flex items-center gap-1.5", className)}>
      <span className="relative inline-flex h-2 w-2">
        <span
          className="absolute inline-flex h-full w-full rounded-full animate-pulse-live"
          style={{ backgroundColor: color }}
        />
        <span
          className="relative inline-flex h-2 w-2 rounded-full"
          style={{ backgroundColor: color }}
        />
      </span>
      {label ? (
        <span
          className="text-micro font-semibold uppercase tracking-[0.14em]"
          style={{ color }}
        >
          {label}
        </span>
      ) : null}
    </span>
  );
}
