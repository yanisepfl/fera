import { Card, CardHeader } from "@/components/ui/Card";

/**
 * The performance-fee explainer, stated as plainly as the pitch requires:
 * "traders pay us nothing; LPs pay 10% of what they earn, only when they earn."
 * Backed by INV-2 (no protocol fee on swaps) + INV-3 (10% of collected LP fees, 0%
 * of principal, under every path).
 */
export function PerfFeeExplainer() {
  return (
    <Card>
      <CardHeader eyebrow="Performance fee" title="How FERA actually makes money" />
      <div className="px-5 pb-5 space-y-4">
        <p className="text-body text-text">
          Traders pay us{" "}
          <span className="font-semibold text-pos">nothing</span>. LPs pay{" "}
          <span className="font-semibold text-accent">10% of what they earn</span> —
          and only when they earn.
        </p>

        <div className="grid gap-3 sm:grid-cols-2">
          <Point
            t="0% on swaps"
            d="No protocol fee is ever taken from a swap, and no swap is ever gated. The dynamic fee is entirely the LPs' (INV-2)."
          />
          <Point
            t="0% on principal"
            d="Deposits, withdrawals, rebalances, compounds, off-hours widens — none touch your principal. The fee only ever applies to collected fees (INV-3)."
          />
          <Point
            t="10% of collected LP fees"
            d="When the vault collects LP fees, exactly 10% is skimmed as the performance fee. Every APR shown on FERA is already net of it."
          />
          <Point
            t="Only when you earn"
            d="No fees collected → no performance fee. FERA is paid strictly out of value it helped LPs capture — never a flat rent."
          />
        </div>

        <div className="rounded-lg border border-line bg-well p-3 text-caption text-mute">
          Caveat surfaced for honesty (PT-3): because the 10% skim raises the
          break-even, a regime pool must charge &gt; ~33.3bp to beat a vanilla 30bp
          pool. That&apos;s why the MEME fee floor is set to 0.34% (0.9 × 34bp &gt; 30bp) —
          it clears the hurdle at the floor itself. FERA also does not deploy the MEME
          regime on no-volatility pairs (Mechanism pool-eligibility rule §5).
        </div>
      </div>
    </Card>
  );
}

function Point({ t, d }: { t: string; d: string }) {
  return (
    <div className="rounded-lg border border-line bg-well p-3">
      <div className="text-body-sm font-semibold text-text">{t}</div>
      <p className="mt-1 text-caption text-mute">{d}</p>
    </div>
  );
}
