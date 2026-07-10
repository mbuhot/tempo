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

// Behaviour-driven coverage of the Origin time / Local time toggle (#57): the
// When column and the find-a-time slot headers both switch between a
// meeting's canonical zone and the viewer's own browser zone, while the
// attendee fairness chips (row-level and wizard-level) stay put — they always
// read each attendee's OWN local time regardless of the toggle. Playwright
// pins the browser zone to Australia/Sydney so every Local-time render is
// deterministic.
//
// The wizard assertion below reads the raw find-a-time API response for its
// EXACT expected string rather than a hardcoded clock reading: the suite's
// other write tests keep booking into this same Marcus/LA search window (the
// event log is append-only), so which slot comes back "first" drifts across
// runs — deriving the expectation from the same instant the UI itself just
// fetched keeps the assertion exact without being tied to a specific slot.
test.describe("the Origin time / Local time toggle", () => {
  test.use({ timezoneId: "Australia/Sydney" });

  const MONTH_ABBREV = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ];
  const SYDNEY_OFFSET_MINUTES = 600; // AEST, no DST in June/July

  function sydneyLocal(iso) {
    const shifted = new Date(
      new Date(iso).getTime() + SYDNEY_OFFSET_MINUTES * 60_000,
    );
    const date = `${shifted.getUTCDate()} ${MONTH_ABBREV[shifted.getUTCMonth()]} ${shifted.getUTCFullYear()}`;
    const hh = String(shifted.getUTCHours()).padStart(2, "0");
    const mm = String(shifted.getUTCMinutes()).padStart(2, "0");
    return { date, time: `${hh}:${mm}` };
  }

  test("switches the When column between a meeting's origin zone and the viewer's browser zone", async ({
    page,
  }) => {
    await signInAs(page, "Admin");
    await navigateTo(page, "Meetings");
    await scrubTo(page, "2026-07-05");

    const row = meetingRow(page, "July all-hands");
    await expect(row).toContainText("09:00 UTC+01:00");
    await expect(row).toContainText("(Europe/London)");

    await page
      .getByRole("group", { name: "Time display" })
      .getByRole("button", { name: "Local time" })
      .click();
    await expect(row).toContainText("18:00 UTC+10:00");
    await expect(row).toContainText("(Australia/Sydney)");
    await expect(row).toContainText("Priya Sharma: 09:00");

    await page
      .getByRole("group", { name: "Time display" })
      .getByRole("button", { name: "Origin time" })
      .click();
    await expect(row).toContainText("09:00 UTC+01:00");
    await expect(row).toContainText("(Europe/London)");
  });

  test("the toggle is a labelled, mutually exclusive pair of pressed buttons", async ({
    page,
  }) => {
    await signInAs(page, "Admin");
    await navigateTo(page, "Meetings");

    const toggle = page.getByRole("group", { name: "Time display" });
    const origin = toggle.getByRole("button", { name: "Origin time" });
    const local = toggle.getByRole("button", { name: "Local time" });
    await expect(origin).toHaveAttribute("aria-pressed", "true");
    await expect(local).toHaveAttribute("aria-pressed", "false");

    await local.click();
    await expect(origin).toHaveAttribute("aria-pressed", "false");
    await expect(local).toHaveAttribute("aria-pressed", "true");
  });

  test("with Local time active, a found slot's header renders in the viewer's browser zone", async ({
    page,
  }) => {
    await signInAs(page, "Admin");
    await navigateTo(page, "Meetings");
    await page
      .getByRole("group", { name: "Time display" })
      .getByRole("button", { name: "Local time" })
      .click();

    await page.getByRole("button", { name: "Find a time" }).click();
    const dialog = page.getByRole("dialog", { name: "Find a time" });
    await dialog.getByLabel("Search engineers").fill("Marcus");
    await dialog
      .getByRole("listitem", { name: "Marcus Chen" })
      .getByRole("button", { name: "Add" })
      .click();
    await dialog.getByLabel("From", { exact: true }).fill("2026-06-23");
    await dialog.getByLabel("To", { exact: true }).fill("2026-06-26");
    await dialog.getByLabel("Duration (minutes)").fill("60");
    await dialog
      .getByRole("combobox", { name: "Timezone" })
      .selectOption("America/Los_Angeles");

    const slots = await page.evaluate(async () => {
      const response = await fetch(
        "/api/meetings/find-a-time?from=2026-06-23&to=2026-06-26&tz=America/Los_Angeles&duration=60&required=2",
      );
      return response.json();
    });
    const [firstCandidate] = slots;
    const start = sydneyLocal(firstCandidate.starts_at);
    const end = sydneyLocal(firstCandidate.ends_at);

    await dialog.getByRole("button", { name: "Find windows" }).click();
    const firstSlot = dialog
      .getByRole("list", { name: "Available windows" })
      .getByRole("listitem")
      .first();
    await expect(firstSlot).toBeVisible();
    await expect(firstSlot).toContainText(
      `${start.date} ${start.time}–${end.time}`,
    );
    await expect(firstSlot).toContainText("(Australia/Sydney)");
  });
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
