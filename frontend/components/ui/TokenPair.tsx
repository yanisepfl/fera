import { cn } from "@/lib/cn";
import type { Token } from "@/lib/types";

/** Monogram token marks + "A / B" label. No external icon deps. */
function Mark({ symbol, z }: { symbol: string; z?: string }) {
  return (
    <span
      className={cn(
        "grid h-6 w-6 place-items-center rounded-full border border-canvas bg-surface text-[10px] font-semibold text-dim",
        z
      )}
      title={symbol}
    >
      {symbol.slice(0, 2)}
    </span>
  );
}

export function TokenPair({
  token0,
  token1,
  className,
  showLabel = true,
}: {
  token0: Token;
  token1: Token;
  className?: string;
  showLabel?: boolean;
}) {
  return (
    <span className={cn("inline-flex items-center gap-2", className)}>
      <span className="flex items-center">
        <Mark symbol={token0.symbol} z="relative z-10" />
        <Mark symbol={token1.symbol} z="-ml-2" />
      </span>
      {showLabel ? (
        <span className="font-medium text-text">
          {token0.symbol}
          <span className="text-mute"> / </span>
          {token1.symbol}
        </span>
      ) : null}
    </span>
  );
}
