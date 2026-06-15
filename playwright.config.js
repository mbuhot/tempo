// @ts-check
const { defineConfig, devices } = require("@playwright/test");

// baseURL is configurable so the same suite can run against:
//   - a self-served placeholder page (default, until the app exists), or
//   - a running Wisp server seeded at v1-wide / v2-split (set TEMPO_BASE_URL in CI).
// When TEMPO_BASE_URL is unset we start a tiny static server over the
// placeholder page so `npx playwright test` is self-contained.
const externalBaseURL = process.env.TEMPO_BASE_URL;
const placeholderURL = "http://127.0.0.1:4321";
const baseURL = externalBaseURL ?? placeholderURL;

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
  // Only spin up the placeholder server when no external app URL was provided.
  webServer: externalBaseURL
    ? undefined
    : {
        command: "npx http-server e2e/placeholder -p 4321 -a 127.0.0.1 -s",
        url: placeholderURL,
        reuseExistingServer: !process.env.CI,
        timeout: 60_000,
      },
});
