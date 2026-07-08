const { test, expect } = require("@playwright/test");
const {
  signInAs,
  navigateTo,
  scrubTo,
  opModal,
  confirmOp,
  escapeRegExp,
} = require("./helpers");

// Behaviour-driven coverage of the Meetings page (Scheduling Phase C): the
// as-of listing shows each meeting's canonical time plus every attendee's own
// local wall-clock time, an admin can schedule/reschedule/cancel a meeting
// with a repeated attendee list, and meeting.manage gates the write actions.
//
// The event log and meeting rows are APPEND-ONLY and never reset between
// runs. The write test titles its meeting with Date.now() so re-running the
// suite always creates and then cancels a fresh, uniquely-named row rather
// than colliding with a prior run's.

// The row for a meeting, by its visible title.
function meetingRow(page, title) {
  return page.getByRole("row", { name: new RegExp(escapeRegExp(title)) });
}

test("the Meetings page lists an upcoming meeting with each attendee's local time", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Meetings");
  await expect(page.getByRole("heading", { name: "Meetings" })).toBeVisible();

  // As-of 2026-07-05: after Priya's relocation to Europe/London (2026-07-01)
  // and before the meeting's own end time, so it is both upcoming and shows
  // her post-relocation local time.
  await scrubTo(page, "2026-07-05");

  const row = meetingRow(page, "July all-hands");
  await expect(row).toContainText("09:00 UTC+01:00");
  await expect(row).toContainText("(Europe/London)");
  await expect(row).toContainText("Priya Sharma: 09:00");
  await expect(row).toContainText("Marcus Chen: 01:00");
});

test("an admin schedules, reschedules, and cancels a meeting", async ({
  page,
}) => {
  const title = `E2E Sync ${Date.now()}`;

  await signInAs(page, "Admin");
  await navigateTo(page, "Meetings");

  await page.getByRole("button", { name: "New meeting" }).click();
  const createModal = opModal(page);
  await expect(createModal.getByText("Schedule meeting")).toBeVisible();

  await createModal.getByLabel("Title").fill(title);
  await createModal.getByLabel("Timezone (IANA TZID)").fill("Europe/London");
  await createModal.getByLabel("Date").fill("2026-08-01");
  await createModal.getByLabel("Start (HH:MM)").fill("10:00");
  await createModal.getByLabel("Duration (minutes)").fill("30");

  await createModal.getByLabel("Search engineers").fill("Priya");
  await createModal
    .getByRole("listitem", { name: "Priya Sharma" })
    .getByRole("button", { name: "Add" })
    .click();

  await createModal.getByLabel("Search engineers").fill("Marcus");
  await createModal
    .getByRole("listitem", { name: "Marcus Chen" })
    .getByRole("button", { name: "Add" })
    .click();
  await createModal
    .getByRole("listitem", { name: "Marcus Chen" })
    .getByRole("combobox", { name: "Attendance" })
    .selectOption("optional");

  await confirmOp(page, "Schedule");
  await expect(opModal(page)).toHaveCount(0);

  let row = meetingRow(page, title);
  await expect(row).toContainText("10:00 UTC+01:00");
  await expect(row).toContainText("(Europe/London)");
  await expect(row).toContainText("Priya Sharma");
  await expect(row).toContainText("Marcus Chen");
  await expect(row).toContainText("Optional");

  // Marcus is Optional: his pill is a "Make required" toggle button. Clicking
  // it flips his attendance (an AddAttendee upsert) and the pill's own text.
  const marcus = row.getByRole("listitem", { name: "Marcus Chen" });
  await expect(marcus).toContainText("Optional");
  await marcus.getByRole("button", { name: "Make required" }).click();
  await expect(marcus).toContainText("Required");
  await expect(
    marcus.getByRole("button", { name: "Make optional" }),
  ).toBeVisible();

  await row.getByRole("button", { name: "Reschedule", exact: true }).click();
  const rescheduleModal = opModal(page);
  await rescheduleModal.getByLabel("Start (HH:MM)").fill("14:00");
  await confirmOp(page, "Reschedule");
  await expect(opModal(page)).toHaveCount(0);

  row = meetingRow(page, title);
  await expect(row).toContainText("14:00 UTC+01:00");
  await expect(row).toContainText("(Europe/London)");

  await row.getByRole("button", { name: "Cancel", exact: true }).click();
  await confirmOp(page, "Cancel meeting");
  await expect(opModal(page)).toHaveCount(0);

  await expect(meetingRow(page, title)).toHaveCount(0);
});

test("a role without meeting.manage sees no meeting write actions", async ({
  page,
}) => {
  await signInAs(page, "Finance");
  await navigateTo(page, "Meetings");
  await expect(page.getByRole("heading", { name: "Meetings" })).toBeVisible();

  await expect(
    page.getByRole("button", { name: "New meeting" }),
  ).toHaveCount(0);

  const row = meetingRow(page, "July all-hands");
  await expect(row).toBeVisible();
  await expect(
    row.getByRole("button", { name: "Reschedule", exact: true }),
  ).toHaveCount(0);
  await expect(
    row.getByRole("button", { name: "Cancel", exact: true }),
  ).toHaveCount(0);
  await expect(
    row.getByRole("button", { name: "Add attendee", exact: true }),
  ).toHaveCount(0);
  await expect(row.getByRole("button", { name: /^Remove / })).toHaveCount(0);
  await expect(
    row.getByRole("button", { name: /^Make (optional|required)$/ }),
  ).toHaveCount(0);
  await expect(row).toContainText("Required");
});
