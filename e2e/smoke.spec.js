const { test, expect } = require("@playwright/test");

// Placeholder smoke test (replaced by one behaviour-driven spec per demo beat in
// Phase 4 — see PRD.md §7 / ARCHITECTURE.md §10.5). Until the app exists this
// only confirms the harness can serve a page, load it, and read its content.
test("the page responds and shows the Tempo heading", async ({ page }) => {
  const response = await page.goto("/");

  // The server responded successfully.
  expect(response).not.toBeNull();
  expect(response.ok()).toBe(true);

  // The user sees the app's name.
  await expect(page.getByRole("heading", { name: "Tempo" })).toBeVisible();
});
