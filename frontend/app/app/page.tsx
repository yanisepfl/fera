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
        subtitle="Regime-aware fees turn toxic, bot, and weekend-drift volume into LP income. Deposit into a managed vault, hold a normal ERC-20 share, and earn fee yield plus esFERA."
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
    </div>
  );
}
