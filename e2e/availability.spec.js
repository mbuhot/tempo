const { test, expect } = require("@playwright/test");
const {
  signInAs,
  navigateTo,
  scrubTo,
  rosterRow,
  clickContent,
  opModal,
  confirmOp,
} = require("./helpers");

// Behaviour-driven coverage of Scheduling Phase B (availability inputs, #43):
// the People-detail Availability panel's weekly-hours grid, focus blocks, and
// holidays strip; the bespoke weekly-hours editor; add/remove focus blocks via
// the op-form engine; the Locations page's public-holidays section and import
// gate; and availability.manage.own vs .any permission gating.

function availabilityPanel(page) {
  return page.locator(".panel", {
    has: page.getByRole("heading", { name: "Availability" }),
  });
}

async function openEngineerDetail(page, name) {
  await navigateTo(page, "People");
  await expect(page.getByRole("heading", { name: "People" })).toBeVisible();
  await clickContent(rosterRow(page, name));
  await expect(page.getByRole("heading", { name: new RegExp(name) })).toBeVisible();
}

test("Priya's Availability panel shows her weekly hours and upcoming holiday", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await openEngineerDetail(page, "Priya Sharma");
  await scrubTo(page, "2026-07-05");

  const panel = availabilityPanel(page);
  await expect(panel).toContainText("Monday");
  await expect(panel).toContainText("09:00–17:00");
  await expect(panel).toContainText("Friday");
  await expect(panel).toContainText("—");
  await expect(panel).toContainText("Summer Bank Holiday");
});

test("Marcus's Availability panel lists his upcoming focus block", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await openEngineerDetail(page, "Marcus Chen");
  await scrubTo(page, "2026-06-16");

  const panel = availabilityPanel(page);
  await expect(panel).toContainText("Deep work: incident review");
});

test("an admin edits Marcus's weekly hours, dropping Wednesday", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await openEngineerDetail(page, "Marcus Chen");
  await scrubTo(page, "2026-07-06");

  await page.getByRole("button", { name: "Edit hours" }).click();
  const editModal = opModal(page);
  await expect(editModal.getByText("Edit weekly hours")).toBeVisible();

  await editModal.getByLabel("Effective").fill("2026-07-06");
  await editModal.getByRole("checkbox", { name: "Wednesday" }).uncheck();
  await confirmOp(page, "Save hours");
  await expect(opModal(page)).toHaveCount(0);

  const panel = availabilityPanel(page);
  await expect(panel).toContainText("Wednesday");
  await expect(panel).toContainText("—");
});

test("an admin adds and removes a focus block on Marcus's detail", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await openEngineerDetail(page, "Marcus Chen");
  await scrubTo(page, "2026-07-05");

  await page.getByRole("button", { name: "Add focus block" }).click();
  const addModal = opModal(page);
  await expect(addModal.getByText("Add focus block")).toBeVisible();

  await addModal.getByLabel("Date").fill("2026-07-15");
  await addModal.getByLabel("Start (HH:MM)").fill("10:00");
  await addModal.getByLabel("Duration (minutes)").fill("60");
  await addModal.getByLabel("Timezone (IANA TZID)").fill("America/Los_Angeles");
  await addModal.getByLabel("Title").fill("Architecture review");
  await confirmOp(page, "Add");
  await expect(opModal(page)).toHaveCount(0);

  const panel = availabilityPanel(page);
  await expect(panel).toContainText("Architecture review");

  await panel
    .locator(".list-row", { hasText: "Architecture review" })
    .getByRole("button", { name: "Remove", exact: true })
    .click();
  const removeModal = opModal(page);
  await expect(removeModal.getByText("Remove focus block")).toBeVisible();
  await confirmOp(page, "Remove");
  await expect(opModal(page)).toHaveCount(0);

  await expect(panel).not.toContainText("Architecture review");
});

test("the Locations page lists public holidays and gates the import button", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Locations");
  await expect(page.getByRole("heading", { name: "Locations" })).toBeVisible();

  const holidaysPanel = page.locator(".panel", {
    has: page.getByRole("heading", { name: "Public holidays" }),
  });
  const labourDayRow = holidaysPanel.getByRole("row", { name: /Labour Day/ });
  await expect(labourDayRow).toContainText("New South Wales");
  await expect(
    holidaysPanel.getByRole("button", { name: "Import holidays" }),
  ).toBeVisible();
});

// Priya (engineer) cannot even open Marcus's detail page — "person.view" is
// itself gated to one's own record for the engineer role, so the panel's
// launcher visibility can't be probed cross-engineer as Priya. Ops (manager)
// holds availability.manage.any but lacks holiday.manage, so it exercises the
// same Owned-vs-Direct split: "Edit hours" everywhere, no holiday Import.
test("a role with availability.manage.any but not holiday.manage sees Edit hours everywhere and no holiday Import", async ({
  page,
}) => {
  await signInAs(page, "Ops");

  await openEngineerDetail(page, "Priya Sharma");
  await expect(
    availabilityPanel(page).getByRole("button", { name: "Edit hours" }),
  ).toBeVisible();

  await openEngineerDetail(page, "Marcus Chen");
  await expect(
    availabilityPanel(page).getByRole("button", { name: "Edit hours" }),
  ).toBeVisible();

  await navigateTo(page, "Locations");
  await expect(page.getByRole("heading", { name: "Locations" })).toBeVisible();
  const holidaysPanel = page.locator(".panel", {
    has: page.getByRole("heading", { name: "Public holidays" }),
  });
  await expect(
    holidaysPanel.getByRole("button", { name: "Import holidays" }),
  ).toHaveCount(0);
});
