const { test, expect } = require("@playwright/test");
const { execFileSync } = require("node:child_process");

// Behaviour-driven coverage of the my-timesheet panel, now a WEEKLY GRID. Drives
// the real app (Wisp serving the Lustre SPA) against a seeded PG19, asserting only
// what the user sees: the projects shown as rows, the hours in each (project, day)
// cell, which cells are editable, and the save feedback — never CSS classes, ids,
// or DOM structure — so the suite is robust to markup changes.
//
// Determinism: the day comes from the slider, whose value is a unix-day index, so
// we drive it to FIXED absolute seed dates rather than the wall clock. The panel
// shows the Monday of the week containing that day as "Week of YYYY-MM-DD".
//
//   2025-05-26 = day 20234  (Monday; Inventory Sync does not begin until the
//                            SUNDAY 2025-06-01, so it is editable only on Sunday)
//   2026-06-08 = day 20612  (Monday of the week Priya logged 4h on each project)
//   2026-06-09 = day 20613  (Tuesday; Priya's logged 4h sit on this column)
//   2026-06-10 = day 20614  (Wednesday; same week, used for Marcus's fresh write)
//   2026-06-15 = day 20619  (Monday; Aisha is on annual leave the whole week)
const DAY = {
  "2025-05-26": "20234",
  "2026-06-08": "20612",
  "2026-06-09": "20613",
  "2026-06-10": "20614",
  "2026-06-15": "20619",
};

// The Monday of the week each scrub date falls in — the date the panel renders in
// its "Week of YYYY-MM-DD (Mon-Sun)" line, our visible confirmation the timesheet
// re-read for that week.
const WEEK_OF = {
  "2025-05-26": "2025-05-26",
  "2026-06-08": "2026-06-08",
  "2026-06-09": "2026-06-08",
  "2026-06-10": "2026-06-08",
  "2026-06-15": "2026-06-15",
};

// Move the slider to a fixed seed day index; the "Week of YYYY-MM-DD (Mon-Sun)"
// line in the panel is the visible confirmation the timesheet re-read that week.
async function scrubTo(page, isoDate) {
  await page.getByLabel("Board date").fill(DAY[isoDate]);
  await expect(
    page.getByText(`Week of ${WEEK_OF[isoDate]} (Mon-Sun)`),
  ).toBeVisible();
}

// Pick an engineer in the timesheet selector by their visible name. Scoped to the
// "My timesheet" region so it resolves to the timesheet's "Engineer" selector and
// not the operations console's (also-"Engineer") roster select on the same page.
async function selectEngineer(page, name) {
  await page
    .getByRole("region", { name: "My timesheet" })
    .getByLabel("Engineer")
    .selectOption({ label: name });
}

// The hours input for one (project, day) cell — labelled by project and ISO day,
// exactly as the user's screen reader announces it.
function cell(page, project, isoDay) {
  return page.getByLabel(`Hours for ${project} on ${isoDay}`);
}

// Restore the shared seed after a write test: drop the timesheet rows the LogWeek
// committed for Marcus on Data Platform across the week, AND the log_week journal
// row the unified operations write path appended for it. Connects over TCP with
// psql using the same env-var defaults as the server (context.gleam), so the same
// cleanup works for the local Docker container and the CI service alike — no
// dependency on a container name.
function restoreMarcusWeek() {
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
      `DELETE FROM timesheet WHERE engineer_id=2 AND project_id=300 ` +
        `AND work_day && daterange('2026-06-08','2026-06-15','[)'); ` +
        `DELETE FROM event_log WHERE operation='log_week' ` +
        `AND (payload->>'engineer_id')::int=2;`,
    ],
    { env: { ...env, PGPASSWORD: env.TEMPO_DB_PASSWORD ?? "tempo" } },
  );
}

test.beforeEach(async ({ page }) => {
  await page.goto("/");
  // The app boots at the seed "now" (2026-06-15), whose week begins Monday
  // 2026-06-15, with the first engineer (Priya) selected.
  await expect(page.getByText("Week of 2026-06-15 (Mon-Sun)")).toBeVisible();
});

test("shows the engineer's allocated projects as rows, with logged hours in the right day column", async ({
  page,
}) => {
  // "I'm Priya", scrub into the week of her logged Tuesday. Both her half-time
  // projects appear as rows, and the 4h she logged on 2026-06-09 sit on that day's
  // cell of each — and nothing she is not allocated to.
  await selectEngineer(page, "Priya Sharma");
  await scrubTo(page, "2026-06-09");

  // Scope the row-label checks to the timesheet region: the project names also
  // appear on the org board and in the console's project select, so an unscoped
  // getByText would be ambiguous.
  const panel = page.getByRole("region", { name: "My timesheet" });
  await expect(panel.getByText("Ledger Migration")).toBeVisible();
  await expect(panel.getByText("Inventory Sync")).toBeVisible();
  await expect(cell(page, "Ledger Migration", "2026-06-09")).toHaveValue("4");
  await expect(cell(page, "Inventory Sync", "2026-06-09")).toHaveValue("4");

  // Marcus's project is not a row in Priya's grid — there is no cell for Data
  // Platform on any day of her week (it appears only on the org board).
  await expect(cell(page, "Data Platform", "2026-06-09")).toHaveCount(0);
});

test("submits a whole week atomically in one click, and every cell persists", async ({
  page,
}) => {
  // The core fix: fill TWO cells of the week and submit them with ONE button.
  // Marcus has nothing logged this week; fill Monday and Tuesday of Data Platform,
  // click "Submit week" once, then reload and re-read — BOTH cells survive,
  // proving one atomic submit with no per-line revert.
  await selectEngineer(page, "Marcus Chen");
  await scrubTo(page, "2026-06-10");

  await expect(cell(page, "Data Platform", "2026-06-08")).toHaveValue("0");
  await expect(cell(page, "Data Platform", "2026-06-09")).toHaveValue("0");

  try {
    await cell(page, "Data Platform", "2026-06-08").fill("5");
    await cell(page, "Data Platform", "2026-06-09").fill("6");
    await page.getByRole("button", { name: "Submit week" }).click();

    await expect(page.getByText("Saved.")).toBeVisible();
    await expect(cell(page, "Data Platform", "2026-06-08")).toHaveValue("5");
    await expect(cell(page, "Data Platform", "2026-06-09")).toHaveValue("6");

    // Reload the whole page; both values are re-fetched from the database.
    await page.reload();
    await selectEngineer(page, "Marcus Chen");
    await scrubTo(page, "2026-06-10");
    await expect(cell(page, "Data Platform", "2026-06-08")).toHaveValue("5");
    await expect(cell(page, "Data Platform", "2026-06-09")).toHaveValue("6");
  } finally {
    restoreMarcusWeek();
  }
});

test("a day the project does not yet cover is not editable", async ({ page }) => {
  // Only cells the engineer's allocation covers that day may be logged. Scrub
  // Priya into the week of Monday 2025-05-26: Inventory Sync begins on the SUNDAY
  // 2025-06-01, so its Monday cell is disabled while its Sunday cell is enabled —
  // the same mechanism that blocks logging after a project ends. Ledger Migration
  // covers the whole week, so its Monday cell is editable.
  await selectEngineer(page, "Priya Sharma");
  await scrubTo(page, "2025-05-26");

  await expect(cell(page, "Inventory Sync", "2025-05-26")).toBeDisabled();
  await expect(cell(page, "Inventory Sync", "2025-06-01")).toBeEnabled();
  await expect(cell(page, "Ledger Migration", "2025-05-26")).toBeEnabled();
});

test("an engineer on leave the whole week has nothing to log", async ({
  page,
}) => {
  // Aisha is on annual leave across the entire week of Monday 2026-06-15. Leave
  // takes precedence over allocation, so she has no loggable day: the grid shows the
  // empty-week message and offers no cell for Data Platform on any day.
  await selectEngineer(page, "Aisha Okafor");
  await scrubTo(page, "2026-06-15");

  await expect(page.getByText("Nothing to log this week.")).toBeVisible();
  await expect(cell(page, "Data Platform", "2026-06-15")).toHaveCount(0);
});
