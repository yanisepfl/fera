import { cn } from "@/lib/cn";
import type { Regime } from "@/lib/types";
import { REGIME_META } from "@/lib/regime";

export function Badge({
  children,
  color,
  wash,
  className,
  dot = false,
}: {
  children: React.ReactNode;
  color?: string;
  wash?: string;
  className?: string;
  dot?: boolean;
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full px-2 py-0.5",
        "text-micro font-semibold uppercase tracking-[0.08em]",
        className
      )}
      style={{
        color: color ?? "var(--text-dim)",
        backgroundColor: wash ?? "var(--ink-800)",
        boxShadow: color ? `inset 0 0 0 1px ${wash ?? "transparent"}` : undefined,
      }}
    >
      {dot ? (
        <span
          className="h-1.5 w-1.5 rounded-full"
          style={{ backgroundColor: color ?? "currentColor" }}
        />
      ) : null}
      {children}
    </span>
  );
}

export function RegimeBadge({
  regime,
  className,
}: {
  regime: Regime;
  className?: string;
}) {
  const m = REGIME_META[regime];
  return (
    <Badge color={m.color} wash={m.wash} dot className={className}>
      {m.label}
    </Badge>
  );
}
