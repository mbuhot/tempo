const { test, expect } = require("@playwright/test");
const { signInAs, navigateTo, scrubTo } = require("./helpers");

test("gaps surface and a nomination previews without saving", async ({ page }) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Schedule");
  await scrubTo(page, "2026-06-15");

  const edge = page.locator("section", { hasText: "Edge Analytics" }).first();
  await expect(edge).toContainText("L3");
  await expect(edge).toContainText("2.0");

  await edge.getByRole("button", { name: "Edge Analytics" }).click();
  const inspector = page.getByRole("complementary");
  await inspector.getByRole("button", { name: "Nominate" }).first().click();
  await inspector.getByRole("button", { name: /Marcus Chen/ }).click();

  await expect(edge).toContainText("1.0");
  await expect(edge).not.toContainText("2.0");

  await page.getByLabel("Preview").uncheck();
  await expect(edge).toContainText("2.0");
});

test("a reschedule outside the contract pills the project header", async ({ page }) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Schedule");
  await scrubTo(page, "2026-06-15");

  const edge = page.locator("section", { hasText: "Edge Analytics" }).first();
  await edge.getByRole("button", { name: "Edge Analytics" }).click();
  const inspector = page.getByRole("complementary");
  await inspector.getByLabel("Run start").fill("2026-05-01");

  await expect(edge).toContainText("outside the containing period");
});

// The inspector drops a reschedule draft that just re-states the project's
// CURRENT run window (nothing to preview), so a re-run against the append-only
// e2e database — where a prior run already landed this exact window — leaves
// "Apply changes" disabled. Only fill and apply when the window is not
// already the target, so the test stays idempotent across runs.
test("applying a reschedule persists the new run window", async ({ page }) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Schedule");
  await scrubTo(page, "2026-06-15");

  const telemetry = page
    .locator("section", { hasText: "Platform Telemetry" })
    .first();
  await telemetry.getByRole("button", { name: "Platform Telemetry" }).click();
  const inspector = page.getByRole("complementary");
  await inspector.getByLabel("Run start").fill("2026-03-01");
  await inspector.getByLabel("Run end").fill("2027-01-01");
  const applyButton = page.getByRole("button", { name: "Apply changes" });
  if (await applyButton.isEnabled().catch(() => false)) {
    await applyButton.click();
  }

  await expect(telemetry).toContainText("2026-03-01 → 2027-01-01");
  await page.reload();
  await expect(
    page.locator("section", { hasText: "Platform Telemetry" }).first(),
  ).toContainText("2026-03-01 → 2027-01-01");
});
