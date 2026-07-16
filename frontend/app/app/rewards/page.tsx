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
        title={
          <>
            Your <span className="text-accent">cut</span>
          </>
        }
        subtitle={
          <>
            Claim what you&apos;ve earned. Stake it for a share of real protocol
            revenue. <span className="text-mute">Paid from fees, not promises.</span>
          </>
        }
      />

      {/* current epoch: countdown, your fees paid and earned, projected esFERA */}
      <EpochPanel />

      <div className="grid gap-6 lg:grid-cols-2">
        {/* left: claim esFERA emissions, then watch them vest to FERA */}
        <div className="space-y-6">
          <ClaimsCard />
          <VestingDashboard />
        </div>

        {/* right: stake FERA for a continuous revenue share (7d unstake cooldown); exit calculator */}
        <div className="space-y-6">
          <StakingPanel />
          <HaircutCalculator />
        </div>
      </div>
    </div>
  );
}
