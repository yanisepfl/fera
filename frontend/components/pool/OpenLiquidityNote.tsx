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
        <span className="font-semibold text-dim">You don&apos;t have to use the vault</span>.
        This pool is open - anyone can provide liquidity directly and manage their own
        range. The <span className="text-accent">vault</span> is the managed, one-tap
        option (and the only one that earns FERA rewards); a skilled hands-on provider
        can earn more per dollar. We won&apos;t pretend otherwise.
      </div>
    );
  }

  return (
    <Card>
      <CardHeader
        eyebrow="Two ways in"
        title="Two ways to provide liquidity"
      />
      <div className="px-5 pb-5 space-y-3">
        <div className="grid gap-3 sm:grid-cols-2">
          <div className="rounded-lg border border-accent-line bg-accent-wash p-3">
            <div className="text-body-sm font-semibold text-text">
              Deposit into the vault
            </div>
            <ul className="mt-1.5 space-y-1 text-caption text-dim">
              <li>· Managed for you, one tap</li>
              <li>· Hold a normal token share; fees auto-compound</li>
              <li>
                · <span className="text-accent">Earns FERA rewards</span>
              </li>
            </ul>
          </div>
          <div className="rounded-lg border border-line bg-well p-3">
            <div className="text-body-sm font-semibold text-text">Provide directly</div>
            <ul className="mt-1.5 space-y-1 text-caption text-dim">
              <li>· Open to anyone: pick your own range</li>
              <li>· Earn trading fees; full manual control</li>
              <li>
                · <span className="text-mute">No FERA rewards</span> - those are the
                vault&apos;s edge
              </li>
            </ul>
          </div>
        </div>
        <p className="text-caption text-mute">
          Straight talk: a skilled provider hand-managing a tight range can earn more fees
          per dollar than the vault. We don&apos;t market the vault as higher-yield -
          it&apos;s the <span className="text-dim">managed, hands-off</span> door. Anyone
          who wants a custom range can deepen this same pool for free.
        </p>
      </div>
    </Card>
  );
}
