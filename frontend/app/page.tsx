import { PageHeader } from "@/components/layout/PageHeader";
import { FeaturedHero } from "@/components/earn/FeaturedHero";
import { PoolList } from "@/components/earn/PoolList";
import { OpenLiquidityNote } from "@/components/pool/OpenLiquidityNote";

export default function EarnPage() {
  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow="Earn"
        title="LP where every flow pays you"
        subtitle="Regime-aware fees turn toxic, bot, and weekend-drift volume into LP income. Deposit into a managed vault, hold a normal ERC-20 share, earn fee-yield plus esFERA."
      />

      <FeaturedHero />

      <OpenLiquidityNote compact />

      <div className="space-y-3">
        <div className="flex items-baseline justify-between">
          <h2 className="text-heading font-semibold">All pools</h2>
          <span className="text-caption text-mute">
            Fees are live · APR is fee-yield + emissions, shown separately
          </span>
        </div>
        <PoolList />
      </div>

      {/* why-it-works trio */}
      <div className="grid gap-3 sm:grid-cols-3">
        {[
          {
            t: "Fees price toxicity",
            d: "MEME fees scale with realized volatility; RWA fees widen off-hours. The more mechanical the flow, the more LPs earn.",
          },
          {
            t: "Principal stays put (MEME)",
            d: "Your principal is a shaped band ladder that isn't churned; fee income drips to follow price. IL is compensated by the fee, not chased with repositioning.",
          },
          {
            t: "Emissions ≤ revenue",
            d: "esFERA issuance can never exceed protocol revenue (β-bounded), split 85/5/10. A dividend of activity, not a subsidy.",
          },
        ].map((x) => (
          <div
            key={x.t}
            className="rounded-lg border border-line bg-card p-4 shadow-card"
          >
            <div className="text-body font-semibold text-text">{x.t}</div>
            <p className="mt-1.5 text-body-sm text-dim">{x.d}</p>
          </div>
        ))}
      </div>
    </div>
  );
}
