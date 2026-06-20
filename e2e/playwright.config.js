// @ts-check
const { defineConfig, devices } = require("@playwright/test");

// Behaviour-driven e2e suite: drives the real app — a running Wisp server serving
// the Lustre SPA against a seeded PG19 — asserting only what the user sees.
//
// baseURL points at the running server; override the host/port with TEMPO_BASE_URL
// (e.g. in CI), defaulting to the dev server's port 8000.
//
// The suite is SELF-MANAGING: the webServer block below has Playwright start the
// Wisp server itself (`cd ../server && gleam run`) and wait for the baseURL before
// the first test, then stop it afterwards. `reuseExistingServer` leaves an
// already-running dev server alone. The first `gleam run` may compile, so the
// startup timeout is generous. The database must already be up + migrated — run
// `bin/db` then `bin/migrate` from the repo root before invoking Playwright.
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
  webServer: {
    command: "cd ../server && gleam run",
    url: baseURL,
    reuseExistingServer: true,
    timeout: 120000,
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
