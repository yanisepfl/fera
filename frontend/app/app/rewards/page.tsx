import type { Metadata } from "next";
import { PageHeader } from "@/components/layout/PageHeader";
import { EpochPanel } from "@/components/rewards/EpochPanel";
import { ClaimsCard } from "@/components/rewards/ClaimsCard";
import { StakingPanel } from "@/components/rewards/StakingPanel";
import { VestingDashboard } from "@/components/rewards/VestingDashboard";
import { HaircutCalculator } from "@/components/rewards/HaircutCalculator";

export const metadata: Metadata = { title: "Rewards" };

export default function RewardsPage() {
  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow="Rewards"
        title="Your epoch, your esFERA"
        subtitle="Emissions track real activity: 85% to LPs (pro-rata to fees earned), 5% to traders (pro-rata to fees paid), and 10% to treasury, capped so issuance can never exceed revenue (INV-7). Claim, vest, or stake for a real revenue share."
      />

      {/* current epoch: countdown + fees paid/earned + projected esFERA */}
      <EpochPanel />

      <div className="grid gap-6 lg:grid-cols-2">
        {/* left: claim finalized epoch → vest esFERA (with instant-exit haircut) */}
        <div className="space-y-6">
          <ClaimsCard />
          <VestingDashboard />
        </div>

        {/* right: stake for revenue share + boost; standalone haircut calculator */}
        <div className="space-y-6">
          <StakingPanel />
          <HaircutCalculator />
        </div>
      </div>
    </div>
  );
}
