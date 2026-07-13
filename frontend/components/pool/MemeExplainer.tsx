import { Card, CardHeader } from "@/components/ui/Card";

/**
 * MEME strategy, v2 (D-11/D-12/D-15). Replaces the old "why we never rebalance" copy with
 * the honest story: principal isn't churned, fee income DRIPS to follow price, and a rare
 * guarded principal recenter fires only after depth degrades past an on-chain floor.
 */
export function MemeExplainer() {
  return (
    <Card>
      <CardHeader
        eyebrow="MEME strategy"
        title="Principal stays put; fee income follows price"
      />
      <div className="px-5 pb-5 space-y-4 text-body-sm text-dim">
        <p>
          Your principal is minted once as a{" "}
          <strong className="text-text">shaped band ladder</strong> (Core / Mid / Tail) and is{" "}
          <strong className="text-text">never churned</strong>. No strategy action closes or
          swaps a principal band (INV-5″). What moves is fee <em>income</em>: collected fees
          drip into fresh no-swap bands at the current price, so the shape&apos;s center of
          mass follows the market without ever realizing your principal&apos;s impermanent
          loss.
        </p>

        <div className="grid gap-3 sm:grid-cols-3">
          {[
            {
              t: "Fee income drips to follow price",
              d: "The 90% LP share of collected fees is deployed daily as new limit-order-style bands at spot. Principal is untouched; only income chases the market (INV-5″).",
            },
            {
              t: "IL is priced, not fought",
              d: "The volatility fee rises as price moves violently, so impermanent loss is compensated by fee income rather than chased with constant repositioning.",
            },
            {
              t: "Toxic flow is the product",
              d: "Wash, bot and one-sided flow pay an elevated (asymmetric) fee. The more mechanical the flow, the more LPs earn.",
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
            The one exception: a rare, guarded recenter
          </div>
          <p className="mt-1 text-caption text-mute">
            Drip alone can lag a fast trend. So principal <em>may</em> recenter, but only when{" "}
            <strong className="text-dim">every</strong> on-chain condition holds, checked and
            enforced by the contract (the keeper can only trigger, never override):
          </p>
          <ul className="mt-2 space-y-1 text-caption text-mute">
            <li className="flex gap-2">
              <span className="text-accent">1.</span> at-spot depth stayed{" "}
              <span className="text-dim">below the full-range-equivalent floor for ≥ 24h</span>{" "}
              (depth actually degraded, not a blip);
            </li>
            <li className="flex gap-2">
              <span className="text-accent">2.</span>{" "}
              <span className="text-dim">≥ 7 days</span> since the last recenter (griefing
              bound);
            </li>
            <li className="flex gap-2">
              <span className="text-accent">3.</span> pool TWAP within{" "}
              <span className="text-dim">±5%</span> sanity band, slippage-capped, timing
              randomized (MEV).
            </li>
          </ul>
          <p className="mt-2 text-caption text-mute">
            If a recenter ever fired outside these bounds the transaction would revert. Worst
            case if it never fires: the ladder simply holds, with degraded depth but never a loss
            beyond the passive full-range outcome (INV-5″/INV-6).
          </p>
        </div>

        <p className="text-caption text-mute">
          Every drip, consolidation and recenter is an on-chain{" "}
          <code className="font-mono text-dim">StrategyAction</code> with a justification hash.
          See the strategy log for this pool&apos;s actual history.
        </p>
      </div>
    </Card>
  );
}
