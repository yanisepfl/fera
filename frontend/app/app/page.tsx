import { PageHeader } from "@/components/layout/PageHeader";
import { FeaturedHero } from "@/components/earn/FeaturedHero";
import { PoolList } from "@/components/earn/PoolList";
import { OpenLiquidityNote } from "@/components/pool/OpenLiquidityNote";

export default function EarnPage() {
  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow="Earn"
        title={
          <>
            Put your coins <span className="text-accent">to work</span>
          </>
        }
        subtitle={
          <>
            Deposit your coins. The vault earns the trading fees for you.{" "}
            <span className="text-mute">The movement does the rest.</span>
          </>
        }
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
