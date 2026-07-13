import { forwardRef } from "react";
import { cn } from "@/lib/cn";

type Variant = "primary" | "secondary" | "ghost" | "danger";
type Size = "sm" | "md" | "lg";

const VARIANTS: Record<Variant, string> = {
  primary:
    "bg-accent text-accent-fg hover:bg-accent-strong active:bg-accent-dim shadow-glow-accent",
  secondary:
    "bg-surface text-text border border-line hover:border-line-strong hover:bg-raised",
  ghost: "text-dim hover:text-text hover:bg-hover",
  danger:
    "bg-danger text-white hover:brightness-110 active:brightness-95 shadow-glow-danger",
};

const SIZES: Record<Size, string> = {
  sm: "h-8 px-3 text-body-sm rounded-sm gap-1.5",
  md: "h-10 px-4 text-body rounded gap-2",
  lg: "h-12 px-6 text-body rounded-lg gap-2",
};

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = "primary", size = "md", ...props }, ref) => (
    <button
      ref={ref}
      className={cn(
        "inline-flex items-center justify-center font-medium whitespace-nowrap select-none",
        "transition-[background,color,border,box-shadow,filter] duration-fast ease-out",
        "disabled:opacity-40 disabled:pointer-events-none",
        VARIANTS[variant],
        SIZES[size],
        className
      )}
      {...props}
    />
  )
);
Button.displayName = "Button";
