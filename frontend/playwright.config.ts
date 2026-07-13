import { defineConfig, devices } from "@playwright/test";

/**
 * FERA E2E config. Skeleton only — NOT run in CI yet.
 *
 * The dev server is started by Playwright on demand (reused if already up). We set
 * NEXT_PUBLIC_GEO_OVERRIDE=FR so the RWA deposit affordance isn't geo-fenced in the
 * flow test (FR is neither blocked nor ack-gated in config/geo.ts), and leave the
 * data source on fixtures (no NEXT_PUBLIC_API_URL / MSW) so the app is fully
 * deterministic and needs no backend.
 *
 * Run locally with:  npm run test:e2e   (installs browsers first: npx playwright install)
 */
export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? "github" : "list",
  timeout: 30_000,
  expect: { timeout: 5_000 },
  use: {
    baseURL: "http://localhost:3000",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
  ],
  webServer: {
    command: "npm run dev",
    url: "http://localhost:3000",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    env: {
      NEXT_PUBLIC_GEO_OVERRIDE: "FR",
    },
  },
});
