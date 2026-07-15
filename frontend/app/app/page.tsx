import { PageHeader } from "@/components/layout/PageHeader";
import { FeaturedHero } from "@/components/earn/FeaturedHero";
import { PoolList } from "@/components/earn/PoolList";
import { OpenLiquidityNote } from "@/components/pool/OpenLiquidityNote";

export default function EarnPage() {
  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow="Earn"
        title="Be the market maker"
        subtitle="Deposit into a vault that provides and auto-manages the liquidity in these pools, and earn a cut of the trading fees. The fee rises when it's volatile - and you can withdraw anytime."
      />

      <FeaturedHero />

      <OpenLiquidityNote compact />

      <div className="space-y-3">
        <div className="flex items-baseline justify-between">
          <h2 className="text-heading font-semibold">All pools</h2>
          <span className="text-caption text-mute">
            Meme coins now · tokenized stocks coming soon
          </span>
        </div>
        <PoolList />
      </div>
    </div>
  );
}
