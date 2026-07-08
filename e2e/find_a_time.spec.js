const { test, expect } = require("@playwright/test");
const { signInAs, navigateTo, escapeRegExp } = require("./helpers");

// Behaviour-driven coverage of the find-a-time wizard (#45): the cross-timezone
// slot finder dialog on the Meetings page, its treatment of optional attendees,
// booking a suggested slot through the RequireFree guard end-to-end, filling the
// attendee list from a project's as-of team, and the empty-state result panel.
//
// Seed cast at "now" 2026-06-15: Priya Sharma (Australia/Sydney, AEST +10:00,
// until 2026-07-01 then Europe/London), Marcus Chen (America/Los_Angeles, PDT
// -07:00), Aisha Okafor (Europe/London, BST +01:00, on leave 2026-06-08 through
// 2026-06-21 inclusive). All three work their default 09:00-17:00 Mon-Fri, so
// every expected local time below is derived from those offsets against the
// slot's UTC instant rather than guessed.

function findATimeDialog(page) {
  return page.getByRole("dialog", { name: "Find a time" });
}

function meetingRow(page, title) {
  return page.getByRole("row", { name: new RegExp(escapeRegExp(title)) });
}

async function openFinder(page) {
  await signInAs(page, "Admin");
  await navigateTo(page, "Meetings");
  await page.getByRole("button", { name: "Find a time" }).click();
  const dialog = findATimeDialog(page);
  await expect(dialog).toBeVisible();
  return dialog;
}

async function addAttendee(dialog, name) {
  await dialog.getByLabel("Search engineers").fill(name);
  await dialog
    .getByRole("listitem", { name })
    .getByRole("button", { name: "Add" })
    .click();
}

test("a cross-timezone search renders the fairness view with each attendee's local time", async ({
  page,
}) => {
  const dialog = await openFinder(page);

  await addAttendee(dialog, "Priya Sharma");
  await addAttendee(dialog, "Marcus Chen");
  await dialog.getByLabel("From", { exact: true }).fill("2026-06-15");
  await dialog.getByLabel("To", { exact: true }).fill("2026-06-19");
  await dialog.getByLabel("Duration (minutes)").fill("60");
  // The Timezone select offers the selected attendees' own zones (Priya's
  // Australia/Sydney, Marcus's America/Los_Angeles) plus UTC; it starts at,
  // and stays at, UTC — the reset rule only fires once the CURRENT selection
  // is no longer among the options, and UTC is always one of them.
  await expect(
    dialog.getByRole("combobox", { name: "Timezone" }),
  ).toHaveValue("UTC");
  await dialog.getByRole("button", { name: "Find windows" }).click();

  const slots = dialog.locator(".finder-slot");
  await expect(slots.first()).toBeVisible();
  await expect(slots).toHaveCount(3);

  const firstSlot = slots.first();
  await expect(firstSlot).toContainText("Priya Sharma: 09:00");
  await expect(firstSlot).toContainText("Marcus Chen: 16:00");
});

test("an optional attendee rides along without narrowing the search", async ({
  page,
}) => {
  const dialog = await openFinder(page);

  await addAttendee(dialog, "Marcus Chen");
  await addAttendee(dialog, "Aisha Okafor");
  await dialog
    .getByRole("listitem", { name: "Aisha Okafor" })
    .getByRole("button", { name: "Make optional" })
    .click();
  await expect(
    dialog
      .getByRole("listitem", { name: "Aisha Okafor" })
      .getByRole("button", { name: "Make required" }),
  ).toBeVisible();
  await dialog.getByLabel("From", { exact: true }).fill("2026-06-15");
  await dialog.getByLabel("To", { exact: true }).fill("2026-06-19");
  await dialog.getByLabel("Duration (minutes)").fill("60");
  // Stays at UTC (the blank default) — it's still a valid option, so nothing
  // resets it.
  await expect(
    dialog.getByRole("combobox", { name: "Timezone" }),
  ).toHaveValue("UTC");
  await dialog.getByRole("button", { name: "Find windows" }).click();

  const slots = dialog.locator(".finder-slot");
  await expect(slots.first()).toBeVisible();
  await expect(slots).toHaveCount(5);

  const firstSlot = slots.first();
  await expect(firstSlot).toContainText("Marcus Chen: 09:00");
  await expect(firstSlot).toContainText("Aisha Okafor: 17:00");
});

test("booking a suggested slot schedules the meeting through the RequireFree guard", async ({
  page,
}) => {
  const title = `Finder e2e ${Date.now()}`;
  const dialog = await openFinder(page);

  await dialog.getByLabel("Title").fill(title);
  await addAttendee(dialog, "Marcus Chen");
  await dialog.getByLabel("From", { exact: true }).fill("2026-06-23");
  await dialog.getByLabel("To", { exact: true }).fill("2026-06-26");
  await dialog.getByLabel("Duration (minutes)").fill("60");
  await dialog
    .getByRole("combobox", { name: "Timezone" })
    .selectOption("America/Los_Angeles");
  await dialog.getByRole("button", { name: "Find windows" }).click();

  const firstSlot = dialog.locator(".finder-slot").first();
  await expect(firstSlot).toBeVisible();
  const attendeeText = await firstSlot
    .locator(".finder-slot__attendees")
    .innerText();
  const [, startTime] = attendeeText.match(/Marcus Chen: (\d{2}:\d{2})/);

  await firstSlot.getByRole("button", { name: "Book this slot" }).click();
  await expect(findATimeDialog(page)).toHaveCount(0);

  await expect(page.getByText(`Booked "${title}"`)).toBeVisible();

  const row = meetingRow(page, title);
  await expect(row).toBeVisible();
  await expect(row).toContainText(startTime);
});

test("filling from a project adds its as-of team to the attendee list", async ({
  page,
}) => {
  const dialog = await openFinder(page);

  await dialog
    .getByRole("combobox", { name: "Fill from project" })
    .selectOption({ label: "Data Platform" });
  await dialog.getByRole("button", { name: "Fill from project" }).click();

  await expect(
    dialog.getByRole("listitem", { name: "Marcus Chen" }),
  ).toBeVisible();
  await expect(
    dialog.getByRole("listitem", { name: "Aisha Okafor" }),
  ).toBeVisible();
});

test("a search with zero common windows shows the empty state and no bookable slots", async ({
  page,
}) => {
  const dialog = await openFinder(page);

  await addAttendee(dialog, "Aisha Okafor");
  await dialog.getByLabel("From", { exact: true }).fill("2026-06-15");
  await dialog.getByLabel("To", { exact: true }).fill("2026-06-19");
  await dialog.getByLabel("Duration (minutes)").fill("60");
  await expect(
    dialog.getByRole("combobox", { name: "Timezone" }),
  ).toHaveValue("UTC");
  await dialog.getByRole("button", { name: "Find windows" }).click();

  await expect(
    dialog.getByText("No windows found for these criteria."),
  ).toBeVisible();
  await expect(
    dialog.getByRole("button", { name: "Book this slot" }),
  ).toHaveCount(0);
});
