import { TopNav } from "@/components/layout/TopNav";

/**
 * App shell (URL segment /app/*). Holds the chrome that used to live in the root
 * layout: the sticky TopNav (with the wallet ConnectButton), the width-capped main,
 * and the LP-first footnote, so the marketing landing at "/" stays chrome-free.
 */
export default function AppLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
      <TopNav />
      <main className="mx-auto w-full max-w-app px-4 py-6 md:px-6 md:py-10">
        {children}
      </main>
      <footer className="mx-auto max-w-app px-4 md:px-6 pb-10 pt-4">
        <div className="hr mb-4" />
        <p className="text-caption text-mute">
          FERA is LP-first infrastructure. Swaps are never gated and never charged a
          protocol fee. Numbers shown are reproducible from on-chain data via
          Backend&apos;s published bundle.
        </p>
      </footer>
    </>
  );
}
