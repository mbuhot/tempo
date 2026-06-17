const { test, expect } = require("@playwright/test");
const { execFileSync } = require("node:child_process");

// Behaviour-driven coverage of the my-timesheet panel. Drives the real app (Wisp
// serving the Lustre SPA) against a seeded PG19, asserting only what the user
// sees: the projects shown, their fractions, the hours in the inputs, the leave
// message, and the save feedback — never CSS classes, ids, or DOM structure — so
// the suite is robust to markup changes.
//
// Determinism: the day comes from the slider, whose value is a unix-day index, so
// we drive it to FIXED absolute seed dates rather than the wall clock.
//
//   2025-01-15 = day 20103  (Priya is only on Ledger Migration; Inventory Sync
//                            does not begin until 2025-06-01 — not offered)
//   2026-06-09 = day 20613  (Priya logged 4h on each of her two projects)
//   2026-06-10 = day 20614  (Marcus is on Data Platform; nothing logged yet)
//   2026-06-15 = day 20619  (seed "now"; Aisha is on annual leave)
const DAY = {
  "2025-01-15": "20103",
  "2026-06-09": "20613",
  "2026-06-10": "20614",
  "2026-06-15": "20619",
};

// Move the slider to a fixed seed day index; the "Logging for YYYY-MM-DD" line in
// the panel is the visible confirmation the timesheet re-read for that day.
async function scrubTo(page, isoDate) {
  await page.getByLabel("Board date").fill(DAY[isoDate]);
  await expect(page.getByText(`Logging for ${isoDate}`)).toBeVisible();
}

// Pick an engineer in the timesheet selector by their visible name. The label is
// matched exactly so it resolves to the timesheet's "Engineer" selector and not
// the operations console's "Engineer id" field (a substring match would hit both).
async function selectEngineer(page, name) {
  await page
    .getByLabel("Engineer", { exact: true })
    .selectOption({ label: name });
}

// The hours input the user types into for a given project.
function hoursInput(page, project) {
  return page.getByLabel(`Hours for ${project}`);
}

// Remove any timesheet row a write test created — AND the log_timesheet journal
// row the unified operations write path now appends for it — restoring the shared
// seed (the canonical empty journal included) regardless of test outcome.
// Connects over TCP with psql using the same env-var defaults as the server
// (context.gleam), so the same cleanup works for the local Docker container and
// the CI service alike — no dependency on a container name.
function restoreSeed(engineerId, projectId, isoDay) {
  const env = process.env;
  execFileSync(
    "psql",
    [
      "-h",
      env.TEMPO_DB_HOST ?? "127.0.0.1",
      "-p",
      env.TEMPO_DB_PORT ?? "5434",
      "-U",
      env.TEMPO_DB_USER ?? "tempo",
      "-d",
      env.TEMPO_DB_NAME ?? "tempo",
      "-c",
      `DELETE FROM timesheet WHERE engineer_id=${engineerId} AND project_id=${projectId} AND work_day @> '${isoDay}'::date; ` +
        `DELETE FROM event_log WHERE operation='log_timesheet' ` +
        `AND (payload->>'engineer_id')::int=${engineerId} ` +
        `AND (payload->>'project_id')::int=${projectId} ` +
        `AND payload->>'day'='${isoDay}';`,
    ],
    { env: { ...env, PGPASSWORD: env.TEMPO_DB_PASSWORD ?? "tempo" } },
  );
}

test.beforeEach(async ({ page }) => {
  await page.goto("/");
  // The app boots at the seed "now" with the first engineer (Priya) selected.
  await expect(page.getByText("Logging for 2026-06-15")).toBeVisible();
});

test("shows only the engineer's allocated projects, with fractions and logged hours", async ({
  page,
}) => {
  // "I'm Priya", scrub to a Tuesday she worked. Her two half-time projects
  // appear, each showing its 50% split and the 4h already on record — and nothing
  // she is not allocated to.
  await selectEngineer(page, "Priya Sharma");
  await scrubTo(page, "2026-06-09");

  await expect(page.getByText("Ledger Migration (50%)")).toBeVisible();
  await expect(page.getByText("Inventory Sync (50%)")).toBeVisible();
  await expect(hoursInput(page, "Ledger Migration")).toHaveValue("4");
  await expect(hoursInput(page, "Inventory Sync")).toHaveValue("4");

  // Marcus's project is not offered for Priya to log against — there is no hours
  // input for Data Platform in her timesheet (it appears only on the org board).
  await expect(hoursInput(page, "Data Platform")).toHaveCount(0);
});

test("a project outside the engineer's allocation that day is not offered for logging", async ({
  page,
}) => {
  // Only projects the engineer is actually allocated to on the selected day may
  // be logged. Scrub Priya back to 2025-01-15 — before her Inventory Sync
  // allocation begins (2025-06-01) — and only Ledger Migration is offered.
  // Inventory Sync is not, because she had not rolled onto it yet; the form
  // refuses to surface a project the day's allocations do not cover.
  await selectEngineer(page, "Priya Sharma");
  await scrubTo(page, "2025-01-15");

  await expect(page.getByText("Ledger Migration (50%)")).toBeVisible();
  await expect(hoursInput(page, "Inventory Sync")).toHaveCount(0);
});

test("an engineer on leave is told there is nothing to log", async ({ page }) => {
  // On the seed "now" Aisha is on annual leave, so the form offers no projects —
  // just the leave state.
  await selectEngineer(page, "Aisha Okafor");
  await scrubTo(page, "2026-06-15");

  await expect(page.getByText("On leave — nothing to log")).toBeVisible();
  await expect(hoursInput(page, "Data Platform")).toHaveCount(0);
});

test("saving hours reflects the new value and persists across a reload", async ({
  page,
}) => {
  // The write path end to end: log fresh hours for Marcus on a day his allocation
  // covers, see them reflected, and confirm they survive a reload — proving the
  // value was committed, not just held in the client.
  await selectEngineer(page, "Marcus Chen");
  await scrubTo(page, "2026-06-10");

  // Nothing logged yet for this day.
  await expect(hoursInput(page, "Data Platform")).toHaveValue("0");

  try {
    await hoursInput(page, "Data Platform").fill("6");
    await page.getByRole("button", { name: "Save Data Platform" }).click();

    // The save is confirmed and the input reflects the saved value.
    await expect(page.getByText("Saved.")).toBeVisible();
    await expect(hoursInput(page, "Data Platform")).toHaveValue("6");

    // Reload the whole page; the value is re-fetched from the database.
    await page.reload();
    await selectEngineer(page, "Marcus Chen");
    await scrubTo(page, "2026-06-10");
    await expect(hoursInput(page, "Data Platform")).toHaveValue("6");
  } finally {
    restoreSeed(2, 300, "2026-06-10");
  }
});

test("submitting an empty hours field shows a friendly message, not a crash", async ({
  page,
}) => {
  // A rejected write is surfaced as a friendly message: clearing the field and
  // saving prompts the user rather than posting a blank or erroring.
  await selectEngineer(page, "Marcus Chen");
  await scrubTo(page, "2026-06-10");

  await hoursInput(page, "Data Platform").fill("");
  await page.getByRole("button", { name: "Save Data Platform" }).click();

  await expect(
    page.getByText("Enter a number of hours before saving."),
  ).toBeVisible();
  // The page is still alive and the project is still shown.
  await expect(page.getByText("Data Platform (100%)")).toBeVisible();
});
