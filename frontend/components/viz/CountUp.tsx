"use client";

import { useEffect, useRef, useState } from "react";
import { cn } from "@/lib/cn";

/**
 * CountUp - animates a number up to `value` once, the first time it scrolls into
 * view (REDESIGN_PLAN.md §2c). Mono + tabular so the width never jitters mid-count.
 *
 * IMPORTANT (honesty): this is only for ILLUSTRATIVE / MODELED figures and epoch
 * projections - never for live on-chain numbers (those keep the existing tick-flash).
 *
 * Reduced-motion: renders the final value immediately, no animation.
 */
export function CountUp({
  value,
  prefix = "",
  suffix = "",
  decimals = 1,
  duration = 700,
  sign = false,
  className,
}: {
  value: number;
  prefix?: string;
  suffix?: string;
  /** Fixed decimal places (kept constant so width is stable). */
  decimals?: number;
  /** Animation length in ms. */
  duration?: number;
  /** Force a leading "+" for positive values (e.g. deltas). */
  sign?: boolean;
  className?: string;
}) {
  const ref = useRef<HTMLSpanElement | null>(null);
  const [display, setDisplay] = useState(0);
  const done = useRef(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    const reduce =
      typeof window !== "undefined" &&
      window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

    // Reduced-motion or no IO support: show the final value immediately.
    if (reduce || typeof IntersectionObserver === "undefined") {
      setDisplay(value);
      done.current = true;
      return;
    }

    let raf = 0;
    const run = () => {
      const start = performance.now();
      const tick = (now: number) => {
        const t = Math.min(1, (now - start) / duration);
        // easeOutCubic - settles gently, matches --ease-out feel.
        const eased = 1 - Math.pow(1 - t, 3);
        setDisplay(value * eased);
        if (t < 1) raf = requestAnimationFrame(tick);
      };
      raf = requestAnimationFrame(tick);
    };

    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting && !done.current) {
            done.current = true;
            run();
            io.disconnect();
          }
        }
      },
      { threshold: 0.4 }
    );
    io.observe(el);

    return () => {
      io.disconnect();
      cancelAnimationFrame(raf);
    };
  }, [value, duration]);

  const rounded = display.toFixed(decimals);
  const signStr = sign && value > 0 && Number(rounded) > 0 ? "+" : "";

  return (
    <span ref={ref} className={cn("font-mono tabular-nums tnum", className)}>
      {signStr}
      {prefix}
      {rounded}
      {suffix}
    </span>
  );
}
