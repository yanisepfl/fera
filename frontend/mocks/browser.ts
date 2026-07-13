/**
 * MSW browser worker. Started from app/providers.tsx only when
 * NEXT_PUBLIC_USE_MSW=1. Requires the generated service worker:
 *   npm run mocks:init   (writes public/mockServiceWorker.js)
 */
import { setupWorker } from "msw/browser";
import { handlers } from "./handlers";

export const worker = setupWorker(...handlers);

export async function startMocks() {
  if (typeof window === "undefined") return;
  if (process.env.NEXT_PUBLIC_USE_MSW !== "1") return;
  await worker.start({
    onUnhandledRequest: "bypass",
    quiet: true,
  });
}
