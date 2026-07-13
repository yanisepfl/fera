import { cn } from "@/lib/cn";

export function Card({
  className,
  as: Tag = "div",
  ...props
}: React.HTMLAttributes<HTMLElement> & { as?: React.ElementType }) {
  return (
    <Tag
      className={cn(
        "rounded-lg border border-line bg-card shadow-card",
        className
      )}
      {...props}
    />
  );
}

export function CardHeader({
  title,
  eyebrow,
  action,
  className,
}: {
  title: React.ReactNode;
  eyebrow?: React.ReactNode;
  action?: React.ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex items-start justify-between gap-4 px-5 pt-5 pb-3",
        className
      )}
    >
      <div className="min-w-0">
        {eyebrow ? <div className="overline mb-1">{eyebrow}</div> : null}
        <h3 className="text-heading font-semibold text-text truncate">
          {title}
        </h3>
      </div>
      {action ? <div className="shrink-0">{action}</div> : null}
    </div>
  );
}
