import { cn } from "@/lib/cn";
import { InfoTip } from "./InfoTip";

/** A labelled numeric readout. Numbers use the mono face + tabular figures. */
export function Stat({
  label,
  value,
  sub,
  tip,
  accent,
  align = "left",
  className,
}: {
  label: React.ReactNode;
  value: React.ReactNode;
  sub?: React.ReactNode;
  tip?: string;
  accent?: string;
  align?: "left" | "right";
  className?: string;
}) {
  return (
    <div
      className={cn(
        "min-w-0",
        align === "right" ? "text-right" : "text-left",
        className
      )}
    >
      <div
        className={cn(
          "flex items-center gap-1 mb-1",
          align === "right" && "justify-end"
        )}
      >
        <span className="overline">{label}</span>
        {tip ? <InfoTip text={tip} /> : null}
      </div>
      <div
        className="font-mono tnum text-heading font-semibold leading-none"
        style={accent ? { color: accent } : undefined}
      >
        {value}
      </div>
      {sub ? <div className="mt-1 text-caption text-mute">{sub}</div> : null}
    </div>
  );
}
