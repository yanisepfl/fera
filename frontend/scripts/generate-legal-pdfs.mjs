// Generate print-friendly PDFs of the legal documents into public/legal/*.pdf.
//
// Single source of truth: this drives the ACTUAL rendered on-site routes
// (/legal/terms, /legal/privacy, /legal/risk) with Playwright's Chromium (already a
// devDependency via @playwright/test) and injects a light print stylesheet ONLY at
// PDF time — so the PDF and the web page can never diverge, and we add no new deps.
//
// Usage (needs a running server serving the app):
//   # terminal A:  (from frontend/)  npm run build && npm run start
//   # terminal B:  LEGAL_BASE_URL=http://localhost:3000 node scripts/generate-legal-pdfs.mjs
//
// If Chromium isn't installed, this prints a one-line install hint and exits 0 (never
// fails a build) — the on-site routes remain the canonical, always-available version.

import { mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = resolve(__dirname, "..", "public", "legal");
const BASE = process.env.LEGAL_BASE_URL ?? "http://localhost:3000";
const DOCS = ["terms", "privacy", "risk"];

// Recolor the dark app to a clean printable light document; hide app chrome.
const PRINT_CSS = `
  :root { color-scheme: light !important; }
  html, body { background: #ffffff !important; }
  * { background-color: transparent !important; background-image: none !important;
      color: #16171a !important; box-shadow: none !important; }
  h1, h2, h3, .overline { color: #0a0a0b !important; }
  a { color: #8a6d16 !important; text-decoration: underline; }
  header, .no-print { display: none !important; }
  hr, [class*="border"] { border-color: #d9dbe0 !important; }
  article { max-width: none !important; padding: 0 !important; }
`;

async function main() {
  let chromium;
  try {
    ({ chromium } = await import("@playwright/test"));
  } catch {
    console.log("[legal-pdf] @playwright/test not available — skipping PDF generation.");
    return;
  }

  await mkdir(OUT_DIR, { recursive: true });

  let browser;
  try {
    browser = await chromium.launch();
  } catch (err) {
    console.log(
      "[legal-pdf] Chromium is not installed — skipping PDF generation.\n" +
        "           Install it once with:  npx playwright install chromium\n" +
        `           (${err instanceof Error ? err.message.split("\n")[0] : String(err)})`,
    );
    return; // exit 0 — web routes are the canonical fallback
  }

  try {
    const page = await browser.newPage();
    for (const id of DOCS) {
      const url = `${BASE}/legal/${id}`;
      const res = await page.goto(url, { waitUntil: "networkidle", timeout: 30_000 });
      if (!res || !res.ok()) throw new Error(`GET ${url} → ${res ? res.status() : "no response"}`);
      await page.addStyleTag({ content: PRINT_CSS });
      await page.emulateMedia({ media: "print" });
      const out = resolve(OUT_DIR, `${id}.pdf`);
      await page.pdf({
        path: out,
        format: "A4",
        printBackground: false,
        margin: { top: "18mm", bottom: "18mm", left: "16mm", right: "16mm" },
      });
      console.log(`[legal-pdf] wrote ${out}`);
    }
  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error("[legal-pdf] generation failed:", err);
  process.exit(1);
});
