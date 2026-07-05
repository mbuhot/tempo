// @ts-check
const { defineConfig, devices } = require("@playwright/test");

// Behaviour-driven e2e suite: drives the real app — a running Wisp server serving
// the Lustre SPA against a seeded PG19 — asserting only what the user sees.
//
// baseURL points at the e2e server on port 8001; override with TEMPO_BASE_URL
// (e.g. in CI). Dev runs on 8000 against tempo, so e2e on 8001 against tempo_e2e
// coexists with a running dev server.
//
// The suite is SELF-MANAGING: the webServer block below has Playwright start the
// Wisp server itself and wait for the baseURL before the first test, then stop it
// afterwards. `reuseExistingServer: false` makes Playwright always spawn its OWN
// server bound to the e2e database + port, never silently reusing a dev server. The
// first `gleam run` may compile, so the startup timeout is generous.
//
// The server is launched against the e2e database (TEMPO_DB_NAME=tempo_e2e) on
// TEMPO_PORT=8001, kept separate from dev (tempo, 8000) and the gleam suite
// (tempo_test). TEMPO_DB_PORT is inherited from the environment, so the host port set
// when invoking `bin/e2e` reaches the server. Bring tempo_e2e to the demo state first
// with `bin/e2e` (which ensures + migrates + base-seeds + seeds the financials demo).
const baseURL = process.env.TEMPO_BASE_URL ?? "http://127.0.0.1:8001";

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
    env: {
      TEMPO_DB_NAME: process.env.TEMPO_DB_NAME ?? "tempo_e2e",
      TEMPO_PORT: "8001",
    },
    url: baseURL,
    reuseExistingServer: false,
    timeout: 120000,
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
