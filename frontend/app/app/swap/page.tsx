import type { Metadata } from "next";
import { PageHeader } from "@/components/layout/PageHeader";
import { SwapCard } from "@/components/swap/SwapCard";

export const metadata: Metadata = { title: "Swap" };

export default function SwapPage() {
  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow="Swap"
        title="Every fee, explained"
        subtitle="FERA pools are ordinary flagless Uniswap v4 pools — any router reaches them. The only thing that moves is the LP fee, and it always tells you why it is what it is."
      />

      <div className="grid gap-6 lg:grid-cols-[1fr_0.8fr]">
        <SwapCard />

        <aside className="space-y-4">
          <div className="rounded-lg border border-line bg-card p-5 shadow-card">
            <div className="overline mb-2">Why the fee moves</div>
            <ul className="space-y-3 text-body-sm text-dim">
              <li>
                <span className="font-medium text-text">MEME:</span> the fee scales
                with EWMA realized volatility and one-sidedness. Calm ≈ 0.34% floor;
                violent, mechanical flow is priced up to ~3–5% so it becomes LP income.
              </li>
              <li>
                <span className="font-medium text-text">RWA:</span> tight (~1–5bp)
                while the underlying market is open; when it closes, the band widens
                and the fee scales with the pool↔Chainlink gap so weekend drift
                arbitrage pays LPs instead of draining them.
              </li>
            </ul>
          </div>
          <div className="rounded-lg border border-line bg-well p-5">
            <div className="overline mb-2">The trader deal</div>
            <p className="text-body-sm text-dim">
              You are never charged a protocol fee, never allow-listed, never paused
              (INV-2 / INV-11). The dynamic fee is the LPs&apos; compensation for
              taking the other side of your flow — nothing is skimmed to FERA.
            </p>
          </div>
        </aside>
      </div>
    </div>
  );
}
