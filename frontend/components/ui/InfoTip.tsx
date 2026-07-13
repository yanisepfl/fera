"use client";

import { useId, useState } from "react";
import { cn } from "@/lib/cn";

/**
 * Minimal accessible info tooltip. Hover or focus reveals a short explanation.
 * Every "why" in FERA (fee reasons, boost, haircut) attaches one of these so the
 * data-dense surface stays legible without a manual.
 */
export function InfoTip({ text, className }: { text: string; className?: string }) {
  const [open, setOpen] = useState(false);
  const id = useId();
  return (
    <span className={cn("relative inline-flex", className)}>
      <button
        type="button"
        aria-describedby={open ? id : undefined}
        aria-label="More info"
        onMouseEnter={() => setOpen(true)}
        onMouseLeave={() => setOpen(false)}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        className="grid h-3.5 w-3.5 place-items-center rounded-full border border-line-strong text-[9px] font-semibold text-mute hover:text-dim hover:border-dim transition-colors"
      >
        i
      </button>
      {open ? (
        <span
          role="tooltip"
          id={id}
          className="absolute bottom-[calc(100%+6px)] left-1/2 z-50 w-56 -translate-x-1/2 rounded-md border border-line-strong bg-raised px-3 py-2 text-caption font-normal normal-case tracking-normal text-dim shadow-pop"
        >
          {text}
        </span>
      ) : null}
    </span>
  );
}
