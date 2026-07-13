import { Card, CardHeader } from "@/components/ui/Card";
import { InfoTip } from "@/components/ui/InfoTip";

/**
 * Emission split 85/5/10 (LPs / traders / treasury) — MASTER_SPEC §7 / §9, FROZEN
 * (Decision-A″, principal 2026-07-12; supersedes the 80/10/10 working prior and the older
 * 45/45/10). Distinct from the RevenueDistributor 50/25/25 split (that's real fee revenue;
 * this is esFERA emissions). Both live on the Transparency page so the two flows are never
 * conflated.
 */
const SPLIT = [
  {
    label: "LPs",
    pct: 85,
    color: "var(--pos)",
    note: "Pro-rata to fees earned. The priority user and the TVL bottleneck (DM-2), so the split is LP-maximal. Boost (≤2×) re-weights this leaf within each pool — never mints (INV-13/PT-5).",
  },
  {
    label: "Traders",
    pct: 5,
    color: "var(--accent)",
    note: "Pro-rata to fees paid. Halved from 10% to 5% — the safest slice: it roughly doubles the wash-farm safety margin at zero routing cost (routing is depth-driven; the rebate accrues to solvers).",
  },
  {
    label: "Treasury",
    pct: 10,
    color: "var(--text-mute)",
    note: "Protocol-owned war-chest kept as the cold-start TVL seed that compounds protocol-owned liquidity (DM-2).",
  },
];

export function EmissionsSplit() {
  return (
    <Card>
      <CardHeader
        eyebrow="Emission split"
        title="Who gets emissions · 85 / 5 / 10"
        action={
          <InfoTip text="Each epoch's emitted esFERA = min(cap(t), β×revenue) is split 85% LPs / 5% traders / 10% treasury (FROZEN, Decision-A″). Applied AFTER boost weighting, normalized within each pool so boost can never import emissions across pools (D-M8)." />
        }
      />
      <div className="px-5 pb-5 space-y-5">
        {/* 85/5/10 bar */}
        <div className="flex h-3 overflow-hidden rounded-full">
          {SPLIT.map((f) => (
            <div
              key={f.label}
              style={{ width: `${f.pct}%`, background: f.color }}
              title={`${f.label} ${f.pct}%`}
            />
          ))}
        </div>

        <div className="grid grid-cols-3 gap-3">
          {SPLIT.map((f) => (
            <div key={f.label} className="rounded-lg border border-line bg-well p-3">
              <div className="flex items-center gap-1.5">
                <span className="h-2 w-2 rounded-full" style={{ background: f.color }} />
                <span className="overline">{f.label}</span>
              </div>
              <div className="mt-1 font-mono tnum text-title font-semibold text-text">
                {f.pct}%
              </div>
              <div className="mt-1 text-caption text-mute">{f.note}</div>
            </div>
          ))}
        </div>

        <p className="text-caption text-mute">
          LP-dominant on purpose: LPs are the priority users. The split is a{" "}
          <span className="text-dim">second-order</span> lever for revenue but a{" "}
          <span className="text-dim">first-order</span> lever for attack surface — halving the
          trader slice to 5% leaves a pure-trader wash farm ~500× underwater vs ~56× at the old
          45/45/10 (sims/split_optimizer.py). Direct pool LPs earn swap fees but zero emissions
          (INV-14) — emissions are the vault&apos;s exclusive carrot.
        </p>
      </div>
    </Card>
  );
}
