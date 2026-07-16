import type { Metadata } from "next";
import { LegalDocView } from "@/components/legal/LegalDocView";
import { TERMS } from "@/lib/legal/content";

export const metadata: Metadata = {
  title: "Terms of Service",
  description: TERMS.summary,
};

export default function TermsPage() {
  return <LegalDocView doc={TERMS} />;
}
