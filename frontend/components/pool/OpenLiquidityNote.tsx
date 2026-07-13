import { Card, CardHeader } from "@/components/ui/Card";

/**
 * Open-liquidity framing with the honesty guardrail baked in.
 *
 * We must NOT claim the vault out-yields direct LPing (measured fee-capture ratio ≤ 0.64 in
 * the revenue-bound regime; emissions bridge only ~8% of the per-$ gap; OD-V10). The honest
 * pitch is: the vault is *managed*, *emissions-eligible*, and *simple*, not higher-yield.
 */
export function OpenLiquidityNote({ compact = false }: { compact?: boolean }) {
  if (compact) {
    return (
      <div className="rounded-lg border border-line bg-well p-3 text-caption text-mute">
        <span className="font-semibold text-dim">Anyone can LP this pool directly</span>. The
        hook is permissionless. Only <span className="text-accent">vault</span> deposits
        earn FERA emissions. Direct LPs earn swap fees but no esFERA. We don&apos;t
        claim the vault out-yields hand-managing your own range. It&apos;s the managed,
        emissions-eligible, one-click option.
      </div>
    );
  }

  return (
    <Card>
      <CardHeader
        eyebrow="Open liquidity"
        title="Two ways to LP this pool"
      />
      <div className="px-5 pb-5 space-y-3">
        <div className="grid gap-3 sm:grid-cols-2">
          <div className="rounded-lg border border-accent-line bg-accent-wash p-3">
            <div className="text-body-sm font-semibold text-text">
              Deposit into the vault
            </div>
            <ul className="mt-1.5 space-y-1 text-caption text-dim">
              <li>· Managed shaped-ladder strategy, one click</li>
              <li>· Hold a normal ERC-20 share; fees auto-compound</li>
              <li>
                · <span className="text-accent">Eligible for FERA emissions</span> (esFERA)
              </li>
            </ul>
          </div>
          <div className="rounded-lg border border-line bg-well p-3">
            <div className="text-body-sm font-semibold text-text">LP directly</div>
            <ul className="mt-1.5 space-y-1 text-caption text-dim">
              <li>· Permissionless: pick your own range</li>
              <li>· Earn swap fees; full manual control</li>
              <li>
                · <span className="text-mute">No FERA emissions</span>. Those are the
                vault&apos;s only carrot
              </li>
            </ul>
          </div>
        </div>
        <p className="text-caption text-mute">
          Straight talk: a skilled LP hand-managing a tight range can capture more fees per
          dollar than the vault. We don&apos;t market the vault as higher-yield. It&apos;s the{" "}
          <span className="text-dim">managed, emissions-eligible, passive</span> door.
          Sophisticated LPs who want a custom range deepen this same pool for free.
        </p>
      </div>
    </Card>
  );
}
