import { test, expect } from "@playwright/test";

/**
 * End-to-end skeleton: DEPOSIT → EARN → CLAIM → STAKE.
 *
 * Runs against fixtures (no backend, no wallet). The deposit affordance is usable
 * without a connected wallet in mock mode (it previews a mocked tx), so the full
 * funnel is exercisable headless. Selectors prefer roles/text so they survive style
 * changes. This is a SKELETON — flesh out assertions as the flow hardens.
 */

test.describe("FERA funnel: deposit → earn → claim → stake", () => {
  test("1. DEPOSIT — deposit into the featured pool from Earn", async ({
    page,
  }) => {
    await page.goto("/");

    // Earn hero shows a LIVE dynamic fee and its reason.
    await expect(page.getByText("LIVE FEE").first()).toBeVisible();

    // Open the hero deposit dialog.
    await page.getByRole("button", { name: "Deposit" }).first().click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();

    // Enter an amount and confirm (mocked tx; geo override = FR → not fenced).
    await dialog.getByPlaceholder("0.00").fill("500");
    await dialog.getByRole("button", { name: /Confirm deposit/i }).click();

    // Success state: vault shares (ERC-20) minted.
    await expect(dialog.getByText(/Deposited into/i)).toBeVisible();
  });

  test("2. EARN — pools list shows fee-yield and emissions APR separately", async ({
    page,
  }) => {
    await page.goto("/");
    // The APR streams are always shown distinctly, never blended.
    await expect(page.getByText(/Fee-yield APR/i).first()).toBeVisible();
    await expect(page.getByText(/Emissions APR/i).first()).toBeVisible();
  });

  test("3. CLAIM — rewards page shows epoch countdown and claim surface", async ({
    page,
  }) => {
    await page.goto("/rewards");

    // Epoch countdown present.
    await expect(page.getByText(/Epoch #/i).first()).toBeVisible();
    await expect(page.getByText(/closes in/i)).toBeVisible();

    // Fees paid / earned drive the rebate vs LP share.
    await expect(page.getByText(/Fees paid/i)).toBeVisible();
    await expect(page.getByText(/Fees earned/i)).toBeVisible();

    // Claim card renders (wallet-gated copy in mock/no-wallet mode).
    await expect(page.getByText(/Claimable esFERA/i)).toBeVisible();

    // Instant-exit haircut must be visible BEFORE any confirmation.
    await expect(page.getByText(/What would exiting cost you/i)).toBeVisible();
  });

  test("4. STAKE — sFERA panel shows revenue-share APR distinct from emissions", async ({
    page,
  }) => {
    await page.goto("/rewards");
    await expect(page.getByText(/sFERA/i).first()).toBeVisible();
    // Real yield (revenue share) is labelled and separated from token emissions.
    await expect(page.getByText(/Revenue-share APR/i)).toBeVisible();
    await expect(page.getByText(/Emissions boost/i)).toBeVisible();
  });

  test("5. SWAP — live regime fee shows a reason", async ({ page }) => {
    await page.goto("/swap");
    await expect(page.getByText(/Live regime fee/i)).toBeVisible();
    // e.g. "Fee 2.10%: volatility elevated" — the reason is always present.
    await expect(page.getByText(/volatility|widened|calm|market/i).first()).toBeVisible();
  });

  test("6. TRANSPARENCY — emissions chart and 50/25/25 split render", async ({
    page,
  }) => {
    await page.goto("/transparency");
    await expect(page.getByText(/Emissions vs cap vs/i)).toBeVisible();
    await expect(page.getByText(/50 . 25 . 25/i)).toBeVisible();
  });
});
