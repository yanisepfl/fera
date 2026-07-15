import { Button } from "./Button";
import { cn } from "@/lib/cn";

/**
 * Reusable load-failure card. Shows friendly, human copy and an optional Retry
 * button (wire it to React Query's `refetch`). Never leak a raw exception string
 * to the user - the technical detail belongs in the console, not the UI.
 */
export function ErrorState({
  title = "Couldn't load this",
  message = "Something went wrong reaching the data. It's usually momentary.",
  onRetry,
  className,
}: {
  title?: string;
  message?: string;
  onRetry?: () => void;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-col items-center gap-3 px-6 py-10 text-center",
        className
      )}
    >
      <div className="grid h-10 w-10 place-items-center rounded-full border border-line-strong bg-well text-body text-mute">
        !
      </div>
      <div>
        <div className="text-body font-semibold text-text">{title}</div>
        <p className="mx-auto mt-1 max-w-xs text-body-sm text-dim">{message}</p>
      </div>
      {onRetry ? (
        <Button variant="secondary" size="sm" onClick={onRetry}>
          Retry
        </Button>
      ) : null}
    </div>
  );
}
