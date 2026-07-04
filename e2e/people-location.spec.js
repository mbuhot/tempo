const { test, expect } = require("@playwright/test");
const { signInAs, navigateTo, scrubTo, rosterRow, clickContent } = require("./helpers");

// Behaviour-driven coverage of the People-detail Overview "Location & timezone"
// card and "Location history" timeline (Scheduling Phase B, #47): Priya
// (engineer 1) relocates from Sydney to London on 2026-07-01 (seeded), so
// scrubbing past that date resolves London on the current card while the
// history timeline still shows both spans.

test("the Overview tab shows an engineer's current location and location history", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "People");
  await expect(page.getByRole("heading", { name: "People" })).toBeVisible();
  await clickContent(rosterRow(page, "Priya Sharma"));
  await expect(
    page.getByRole("heading", { name: /Priya Sharma/ }),
  ).toBeVisible();

  await scrubTo(page, "2026-07-15");

  const currentCard = page.locator(".panel", {
    has: page.getByRole("heading", { name: "Location & timezone" }),
  });
  await expect(currentCard).toContainText("Europe/London");
  await expect(currentCard).toContainText("UTC+01:00");

  const historyPanel = page.locator(".panel", {
    has: page.getByRole("heading", { name: "Location history" }),
  });
  await expect(historyPanel).toContainText("Australia/Sydney");
  await expect(historyPanel).toContainText("Europe/London");
});
