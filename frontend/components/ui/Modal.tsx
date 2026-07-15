"use client";

import { useEffect, useId } from "react";
import { cn } from "@/lib/cn";

export function Modal({
  open,
  onClose,
  title,
  children,
  className,
}: {
  open: boolean;
  onClose: () => void;
  title?: React.ReactNode;
  children: React.ReactNode;
  className?: string;
}) {
  const titleId = useId();

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    document.addEventListener("keydown", onKey);
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = "";
    };
  }, [open, onClose]);

  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 grid place-items-end sm:place-items-center">
      <div
        className="absolute inset-0 bg-black/60 backdrop-blur-sm animate-fade-up"
        onClick={onClose}
        aria-hidden
      />
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby={title ? titleId : undefined}
        className={cn(
          "relative z-10 w-full sm:max-w-md rounded-t-lg sm:rounded-lg border border-line-strong bg-raised shadow-pop animate-fade-up",
          className
        )}
      >
        {title ? (
          <div className="flex items-center justify-between border-b border-line px-5 py-4">
            <h3 id={titleId} className="text-heading font-semibold">{title}</h3>
            <button
              onClick={onClose}
              aria-label="Close"
              className="grid h-7 w-7 place-items-center rounded-md text-mute hover:bg-hover hover:text-text transition-colors"
            >
              ✕
            </button>
          </div>
        ) : null}
        {children}
      </div>
    </div>
  );
}
