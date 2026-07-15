import { Card, CardHeader } from "@/components/ui/Card";

/**
 * MEME strategy, v2. Replaces the old "why we never rebalance" copy with
 * the honest story: principal isn't churned, fee income DRIPS to follow price, and a rare
 * guarded principal recenter fires only after depth degrades past an on-chain floor.
 */
export function MemeExplainer() {
  return (
    <Card>
      <CardHeader
        eyebrow="How this pool is managed"
        title="Your position stays put - the fees do the moving"
      />
      <div className="px-5 pb-5 space-y-4 text-body-sm text-dim">
        <p>
          Your deposit is spread across a{" "}
          <strong className="text-text">shaped range</strong> once, and then left
          alone - the vault doesn&apos;t constantly buy and sell your position. What
          moves is the fees you earn: they&apos;re re-added as fresh liquidity near the
          current price, so your earning range keeps up with the market without ever
          cashing out your position at a loss.
        </p>

        <div className="grid gap-3 sm:grid-cols-3">
          {[
            {
              t: "Fees follow the price",
              d: "The fees your position earns get re-deployed near the current price, so your liquidity keeps tracking the market. Your original deposit is left untouched.",
            },
            {
              t: "Volatility is paid for, not fought",
              d: "Rather than chase the price with constant repositioning, the fee simply rises when the market moves hard - so the swings are compensated instead of resisted.",
            },
            {
              t: "Busy markets pay more",
              d: "Fast, one-sided, bot-driven trading pays a higher fee. The more frantic the market, the more you earn for providing into it.",
            },
          ].map((x) => (
            <div key={x.t} className="rounded-lg border border-line bg-well p-3">
              <div className="text-body-sm font-semibold text-text">{x.t}</div>
              <p className="mt-1 text-caption text-mute">{x.d}</p>
            </div>
          ))}
        </div>

        {/* the honest exception: guarded recenter */}
        <div className="rounded-lg border border-line bg-card p-3">
          <div className="text-body-sm font-semibold text-text">
            The one exception: a rare, safety-checked reset
          </div>
          <p className="mt-1 text-caption text-mute">
            Letting only the fees move can lag a fast, sustained trend. So the vault{" "}
            <em>may</em> occasionally reset your range - but only when{" "}
            <strong className="text-dim">every</strong> safety condition below is met,
            all enforced by the contract itself (an operator can trigger it, never
            override it):
          </p>
          <ul className="mt-2 space-y-1 text-caption text-mute">
            <li className="flex gap-2">
              <span className="text-accent">1.</span> your range has been{" "}
              <span className="text-dim">too shallow for at least 24 hours</span> (a real
              drop in depth, not a blip);
            </li>
            <li className="flex gap-2">
              <span className="text-accent">2.</span> at least{" "}
              <span className="text-dim">7 days</span> since the last reset;
            </li>
            <li className="flex gap-2">
              <span className="text-accent">3.</span> the pool price is within{" "}
              <span className="text-dim">±5%</span> of a recent average, with slippage
              capped and timing randomized to deter front-running.
            </li>
          </ul>
          <p className="mt-2 text-caption text-mute">
            If a reset ever tried to fire outside these limits, the transaction would
            simply fail. Worst case, if it never fires: your range just holds where it
            is - shallower, but never a loss beyond a plain hold.
          </p>
        </div>

        <p className="text-caption text-mute">
          Every fee re-deployment and reset is recorded on-chain with a reason. See this
          pool&apos;s strategy log for its actual history.
        </p>
      </div>
    </Card>
  );
}
