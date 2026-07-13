/**
 * MSW node server — for Playwright/component tests that want intercepted network
 * without a running backend. Import and `server.listen()` in a test setup file.
 */
import { setupServer } from "msw/node";
import { handlers } from "./handlers";

export const server = setupServer(...handlers);
