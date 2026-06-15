// @ts-check
const { defineConfig, devices } = require("@playwright/test");

// The behaviour-driven e2e suite (one spec per demo beat, PRD §7 /
// ARCHITECTURE.md §10.5) drives the real app: a running Wisp server serving the
// Lustre SPA against a migrated + seeded PG19. The same suite must pass
// unmodified against both `v1-wide` and `v2-split` (the v2 state is the v1 seed
// after the migration), so it asserts only what the user sees.
//
// baseURL points at the running server; override the host/port with
// TEMPO_BASE_URL (e.g. in CI) but it defaults to the dev server's port 8000
// (src/tempo.gleam). Start the app before running:
//   cd client && gleam run -m lustre/dev build client/app   # bundle → ../priv/static
//   gleam run                                               # serve on :8000 (repo root)
//   npx playwright test
const baseURL = process.env.TEMPO_BASE_URL ?? "http://127.0.0.1:8000";

module.exports = defineConfig({
  testDir: "./e2e",
  // Deterministic CI: fail the build if a `test.only` is left in the source.
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    baseURL,
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
