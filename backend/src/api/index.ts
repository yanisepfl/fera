// Ponder serves the default-exported Hono app from this path (apiDir = <root>/src/api). The FERA
// API implementation lives in backend/api/ (per the backend layout); this file just re-exports it
// so `ponder serve` / `ponder start` mount the routes. Do not add logic here.
export { default } from "../../api/index";
