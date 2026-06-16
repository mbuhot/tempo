// @ts-check
const { defineConfig, devices } = require("@playwright/test");

// Behaviour-driven e2e suite: drives the real app — a running Wisp server serving
// the Lustre SPA against a seeded PG19 — asserting only what the user sees.
//
// baseURL points at the running server; override the host/port with TEMPO_BASE_URL
// (e.g. in CI), defaulting to the dev server's port 8000. Start the app first:
//   cd client && gleam run -m lustre/dev build client/app   # bundle → ../server/priv/static
//   cd server && gleam run                                  # serve on :8000
//   npx playwright test
const baseURL = process.env.TEMPO_BASE_URL ?? "http://127.0.0.1:8000";

module.exports = defineConfig({
  testDir: ".",
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
