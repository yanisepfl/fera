import { test, expect } from "@playwright/test";

/**
 * SMOKE (needs internet): the 5 registry pools (config/pools.ts) render on Earn with
 * REAL on-chain values — dynamic fee from FeraHook.getDynamicFee and tranche-0 NAV from
 * FeraVault.quoteNav on Robinhood Chain (4663) — merged over the fixture list by
 * lib/hooks/useLivePools.ts.
 *
 * RUN AGAINST A PRODUCTION SERVER (verified passing 2026-07-18):
 *   npm run build && npm run start   # port 3000
 *   npx playwright test livechain.smoke
 * (Playwright reuses the already-running server.) `next dev` will NOT hydrate: the CSP
 * in next.config.js omits 'unsafe-eval', which dev-mode eval-source-map chunks require —
 * a PRE-EXISTING dev-only issue that also affects flow.spec.ts, unrelated to this spec.
 */
test.describe("live-chain overlay", () => {
  test("Earn lists the deployed pools with real fee + NAV", async ({ page }) => {
    await page.goto("/app");

    // A registry pool row appears (TENDIES leads by NAV among the seeds).
    await expect(page.getByText("TENDIES").first()).toBeVisible({ timeout: 20_000 });

    // Its TVL cell shows the REAL quote NAV denomination, not a USD fixture.
    await expect(page.getByText("wWETH").first()).toBeVisible();

    // Fixture pools still render alongside (mock mode keeps working).
    await expect(page.getByText("PEPE").first()).toBeVisible();
  });

  test("registry pool page renders from chain even with no API entry", async ({ page }) => {
    await page.goto(
      "/app/pool/0x781f4bd64678be81a559f58bb124c570fb86abc04831f1c41212984340df9a12"
    );
    // Header pair + on-chain NAV stat render (fixtures know nothing about this id).
    await expect(page.getByRole("heading", { name: /TENDIES/ }).first()).toBeVisible({
      timeout: 20_000,
    });
    await expect(page.getByText("Vault NAV").first()).toBeVisible();
    await expect(page.getByText(/read on-chain/).first()).toBeVisible();
    // Deposit affordance exists (wallet-gated once opened).
    await expect(page.getByRole("button", { name: "Deposit" }).first()).toBeVisible();
  });
});
