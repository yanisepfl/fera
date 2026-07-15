/**
 * App preview banner. The app runs on sample fixtures, not a live indexer: TVL,
 * APRs, positions, and the "live" fee are illustrative until the on-chain backend
 * is wired. FERA's whole thesis is that numbers are verifiable, so we say plainly
 * that this is a preview and the figures are sample data. Slim, always-on, calm.
 */
export function PreviewBanner() {
  return (
    <div className="border-b border-accent-line bg-accent-wash">
      <div className="mx-auto flex max-w-app items-center gap-2.5 px-4 py-2 md:px-6">
        <span
          aria-hidden
          className="h-1.5 w-1.5 shrink-0 rounded-full bg-accent"
        />
        <p className="text-caption text-dim">
          <span className="font-semibold text-accent">Preview</span> · figures are
          sample data to demo the interface, not live on-chain values. Deposits,
          claims, and staking are not active yet.
        </p>
      </div>
    </div>
  );
}
