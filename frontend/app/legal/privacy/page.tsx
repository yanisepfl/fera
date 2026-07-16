import type { Metadata } from "next";
import { LegalDocView } from "@/components/legal/LegalDocView";
import { PRIVACY } from "@/lib/legal/content";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description: PRIVACY.summary,
};

export default function PrivacyPage() {
  return <LegalDocView doc={PRIVACY} />;
}
