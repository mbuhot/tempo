const { test, expect } = require("@playwright/test");
const {
  signInAs,
  navigateTo,
  scrubTo,
  rosterRow,
  opModal,
  confirmOp,
} = require("./helpers");

// Behaviour-driven coverage of the Locations page (Scheduling Phase A): the
// as-of listing resolves each engineer's country/timezone on the rail date,
// and an admin can set a new location from the page.
//
// The event log and facts are APPEND-ONLY and never reset between runs. The
// write test targets Marcus Chen (seeded America/Los_Angeles, open-ended)
// with a fixed future effective date already registered in helpers'
// DAY_INDEX (2026-12-15, within the rail's range), so re-running the test
// re-states the same location from the same date every time — idempotent
// and re-run safe.

test("an engineer's timezone reflects the as-of date across a relocation", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Locations");
  await expect(page.getByRole("heading", { name: "Locations" })).toBeVisible();

  await scrubTo(page, "2026-06-15");
  await expect(rosterRow(page, "Priya Sharma")).toContainText(
    "Australia/Sydney",
  );
  await expect(rosterRow(page, "Priya Sharma")).toContainText("UTC+10:00");

  await scrubTo(page, "2026-07-15");
  await expect(rosterRow(page, "Priya Sharma")).toContainText(
    "Europe/London",
  );
  await expect(rosterRow(page, "Priya Sharma")).toContainText("UTC+01:00");
});

test("an admin sets an engineer's location", async ({ page }) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Locations");

  await rosterRow(page, "Marcus Chen")
    .getByRole("button", { name: "Set location" })
    .click();

  await expect(page.getByLabel("Country")).toBeVisible();
  await page.getByLabel("Country").fill("JP");
  await page.getByLabel("Region").fill("");
  await page.getByLabel("Timezone (IANA TZID)").fill("Asia/Tokyo");
  await page.getByLabel("Effective").fill("2026-12-15");
  await confirmOp(page, "Set location");
  await expect(opModal(page)).toHaveCount(0);

  await scrubTo(page, "2026-12-15");
  const relocatedRow = rosterRow(page, "Marcus Chen");
  await expect(relocatedRow).toContainText("JP");
  await expect(relocatedRow).toContainText("Asia/Tokyo");
  await expect(relocatedRow).toContainText("UTC+09:00");
  await expect(relocatedRow).toContainText("15 Dec 2026");
});
