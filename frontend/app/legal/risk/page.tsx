import type { Metadata } from "next";
import { LegalDocView } from "@/components/legal/LegalDocView";
import { RISK } from "@/lib/legal/content";

export const metadata: Metadata = {
  title: "Risk Disclosure",
  description: RISK.summary,
};

export default function RiskPage() {
  return <LegalDocView doc={RISK} />;
}
