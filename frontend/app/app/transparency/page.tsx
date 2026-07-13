import type { Metadata } from "next";
import { PageHeader } from "@/components/layout/PageHeader";
import { EmissionsChart } from "@/components/transparency/EmissionsChart";
import { EmissionsSplit } from "@/components/transparency/EmissionsSplit";
import { RevenueFlows } from "@/components/transparency/RevenueFlows";
import { PerfFeeExplainer } from "@/components/transparency/PerfFeeExplainer";
import { InvariantLinks } from "@/components/transparency/InvariantLinks";

export const metadata: Metadata = { title: "Transparency" };

export default function TransparencyPage() {
  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow="Transparency"
        title="The numbers, and where they come from"
        subtitle="Emissions capped by revenue and split 85/5/10 to LPs/traders/treasury, real revenue split 50/25/25, a performance fee that only bites when LPs win — each backed by an on-chain invariant test. Nothing here is a projection you have to take on faith."
      />

      {/* the tokenomics-pitch chart: emissions vs cap AND vs β-bound */}
      <EmissionsChart />

      {/* two distinct flows: esFERA emission split (85/5/10) vs real revenue split (50/25/25) */}
      <div className="grid gap-6 lg:grid-cols-2">
        <EmissionsSplit />
        <RevenueFlows />
      </div>

      <PerfFeeExplainer />

      <InvariantLinks />
    </div>
  );
}
