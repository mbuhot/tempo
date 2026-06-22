const { test, expect } = require("@playwright/test");
const {
  signInAs,
  navigateTo,
  scrubTo,
  rosterRow,
  clickContent,
} = require("./helpers");

// Behaviour-driven coverage of the WEEKLY timesheet grid, now hosted on a People
// DETAIL page (/people/:id). We sign in, open an engineer's detail from the
// roster, and drive the rail to a fixed seed week; the panel shows the week of the
// Monday containing that date ("week of YYYY-MM-DD"). We assert only what the user
// sees: the projects shown as rows, the hours in each (project, day) cell, which
// cells are editable, and that a logged week persists — never CSS classes, ids, or
// DOM structure.
//
// The rail's slider value is a unix-day index, so we anchor to FIXED seed dates:
//   2025-05-26 = Monday (Inventory Sync begins SUNDAY 2025-06-01)
//   2026-06-08 = Monday of the week Priya logged 4h on each project (Tue 06-09)
//   2026-06-15 = Monday; Aisha is on annual leave the whole week

// Open one engineer's detail from the roster. (Signed in as a different person so
// the detail's name heading is never the sidebar's signed-in-user name.)
async function openDetail(page, name) {
  await navigateTo(page, "People");
  await expect(page.getByRole("heading", { name: "People" })).toBeVisible();
  await clickContent(rosterRow(page, name));
  await expect(page.getByRole("heading", { name: new RegExp(name) })).toBeVisible();
}

// The Hours input for a (project, weekday) cell: scoped to the project's grid row,
// then the weekday column by 0-based index Mon..Sun. The cell's accessible name is
// "Hours"; the row + column position pins the exact day, exactly as a user reads
// the grid left-to-right.
function cell(page, project, weekdayIndex) {
  return page
    .getByRole("row", { name: new RegExp(project) })
    .getByLabel("Hours")
    .nth(weekdayIndex);
}

const WEEKDAY = { Mon: 0, Tue: 1, Wed: 2, Thu: 3, Fri: 4, Sat: 5, Sun: 6 };

test("shows the engineer's allocated projects as rows, with logged hours in the right day column", async ({
  page,
}) => {
  // "I'm Aisha looking at Priya." Open Priya's detail and scrub into the week of
  // her logged Tuesday (2026-06-09). Both her half-time projects are rows, and the
  // 4h she logged on Tuesday sit on that day's cell of each.
  await signInAs(page, "Aisha Okafor");
  await scrubTo(page, "2026-06-09");
  await openDetail(page, "Priya Sharma");

  await expect(page.getByText("week of 2026-06-08")).toBeVisible();
  await expect(cell(page, "Ledger Migration", WEEKDAY.Tue)).toHaveValue("4");
  await expect(cell(page, "Inventory Sync", WEEKDAY.Tue)).toHaveValue("4");
  // The seed logs every Mon–Fri working day, so Monday carries her 4h too; the
  // weekend is not a working day, so Sunday's cell stays empty.
  await expect(cell(page, "Ledger Migration", WEEKDAY.Mon)).toHaveValue("4");
  await expect(cell(page, "Ledger Migration", WEEKDAY.Sun)).toHaveValue("");
  // Priya is not on Data Platform, so it is not a row in her grid.
  await expect(
    page.getByRole("row", { name: /Data Platform/ }).getByLabel("Hours"),
  ).toHaveCount(0);
});

test("logging a whole week persists across navigation", async ({ page }) => {
  // Fill TWO cells of Marcus's week and submit them with ONE "Log week" click, then
  // navigate away and back (a client-side refetch from the database) — both cells
  // survive, proving one atomic submit. Re-run safe: the write overwrites the same
  // cells with the same values each run (no reliance on the cells starting empty).
  await signInAs(page, "Aisha Okafor");
  await scrubTo(page, "2026-06-10");
  await openDetail(page, "Marcus Chen");
  await expect(page.getByText("week of 2026-06-08")).toBeVisible();

  await cell(page, "Data Platform", WEEKDAY.Mon).fill("5");
  await cell(page, "Data Platform", WEEKDAY.Tue).fill("6");
  await page.getByRole("button", { name: "Log week" }).dispatchEvent("click");

  await expect(cell(page, "Data Platform", WEEKDAY.Mon)).toHaveValue("5");
  await expect(cell(page, "Data Platform", WEEKDAY.Tue)).toHaveValue("6");

  // Leave the detail and return through the roster — the grid re-reads from the
  // database (the server does not serve /people/:id on a cold reload, so we
  // re-navigate client-side rather than page.reload()).
  await navigateTo(page, "Board");
  await expect(page.getByRole("heading", { name: "Board" })).toBeVisible();
  await openDetail(page, "Marcus Chen");
  await scrubTo(page, "2026-06-10");
  await expect(cell(page, "Data Platform", WEEKDAY.Mon)).toHaveValue("5");
  await expect(cell(page, "Data Platform", WEEKDAY.Tue)).toHaveValue("6");
});

test("a day the project does not yet cover is not editable", async ({ page }) => {
  // Only cells the engineer's allocation covers that day may be logged. Scrub Priya
  // into the week of Monday 2025-05-26: Inventory Sync begins the SUNDAY
  // 2025-06-01, so its Monday cell is disabled while its Sunday cell is enabled;
  // Ledger Migration covers the whole week, so its Monday cell is editable.
  await signInAs(page, "Aisha Okafor");
  await scrubTo(page, "2025-05-26");
  await openDetail(page, "Priya Sharma");
  await expect(page.getByText("week of 2025-05-26")).toBeVisible();

  await expect(cell(page, "Inventory Sync", WEEKDAY.Mon)).toBeDisabled();
  await expect(cell(page, "Inventory Sync", WEEKDAY.Sun)).toBeEnabled();
  await expect(cell(page, "Ledger Migration", WEEKDAY.Mon)).toBeEnabled();
});

test("an engineer on leave the whole week has nothing to log", async ({
  page,
}) => {
  // Aisha is on annual leave across the entire week of Monday 2026-06-15. Leave
  // takes precedence over allocation, so her grid shows the empty-week message and
  // offers no cell to log against.
  await signInAs(page, "Priya Sharma");
  await scrubTo(page, "2026-06-15");
  await openDetail(page, "Aisha Okafor");

  await expect(page.getByText("Nothing to log this week.")).toBeVisible();
  await expect(page.getByLabel("Hours")).toHaveCount(0);
});
