import { TopNav } from "@/components/layout/TopNav";
import { PreviewBanner } from "@/components/layout/PreviewBanner";

/**
 * App shell (URL segment /app/*). Holds the chrome that used to live in the root
 * layout: the sticky TopNav (with the wallet ConnectButton) and the width-capped
 * main, so the marketing landing at "/" stays chrome-free.
 */
export default function AppLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
      <TopNav />
      <PreviewBanner />
      <main className="mx-auto w-full max-w-app px-4 py-6 md:px-6 md:py-10">
        {children}
      </main>
    </>
  );
}
