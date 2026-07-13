import { Card, CardHeader } from "@/components/ui/Card";

/**
 * Links to the invariant tests that back every claim on this page. Contracts (2)
 * owns a test per invariant (MASTER_SPEC §2); Security (6) owns a PoC attempting to
 * break each. Canonical location: contracts/test/invariant/. The repo base is
 * env-driven so this points at the real host once published.
 */
const REPO =
  process.env.NEXT_PUBLIC_REPO_URL?.replace(/\/$/, "") ??
  "https://github.com/fera-protocol/fera";
const TESTS_PATH = "contracts/test/invariant";
const testUrl = (file?: string) =>
  `${REPO}/tree/main/${TESTS_PATH}${file ? `/${file}` : ""}`;

const INVARIANTS: { id: string; text: string; file: string }[] = [
  {
    id: "INV-2",
    text: "Swaps never reverted for being non-allowlisted; hook never takes a protocol fee from a swap.",
    file: "Swap_NoProtocolFee.t.sol",
  },
  {
    id: "INV-3",
    text: "Performance fee is exactly 10% of collected LP fees and 0% of principal, under every path.",
    file: "PerfFee_TenPercent.t.sol",
  },
  {
    id: "INV-7",
    text: "Epoch emission ≤ min(cap(t), β × epochRevenueValuedInFera). Enforced in EmissionsController.",
    file: "Emissions_RevenueBound.t.sol",
  },
  {
    id: "INV-9",
    text: "esFERA forfeiture conserves value: burned + toStakers + toRevenue == haircut, 1/3 each.",
    file: "Forfeit_Conservation.t.sol",
  },
  {
    id: "INV-10",
    text: "RevenueDistributor splits every inflow exactly 50/25/25 with no rounding dust escaping.",
    file: "Revenue_Split_50_25_25.t.sol",
  },
];

export function InvariantLinks() {
  return (
    <Card>
      <CardHeader
        eyebrow="Verify, don't trust"
        title="Invariant tests behind these numbers"
        action={
          <a
            href={testUrl()}
            target="_blank"
            rel="noopener noreferrer"
            className="text-caption text-accent hover:text-accent-strong"
          >
            {TESTS_PATH}/ ↗
          </a>
        }
      />
      <div className="px-5 pb-5">
        <ul className="divide-y divide-line">
          {INVARIANTS.map((inv) => (
            <li key={inv.id} className="flex items-start gap-3 py-3">
              <a
                href={testUrl(inv.file)}
                target="_blank"
                rel="noopener noreferrer"
                className="mt-0.5 shrink-0 rounded-md bg-accent-wash px-2 py-0.5 font-mono text-caption font-semibold text-accent hover:bg-accent-line"
              >
                {inv.id}
              </a>
              <span className="text-body-sm text-dim">{inv.text}</span>
            </li>
          ))}
        </ul>
        <p className="mt-2 text-caption text-mute">
          Full invariant set (INV-1…INV-13) in MASTER_SPEC §2. Every figure on FERA
          is reproducible from on-chain data via Backend&apos;s published bundle (§9).
        </p>
      </div>
    </Card>
  );
}
