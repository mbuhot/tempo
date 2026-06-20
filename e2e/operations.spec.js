const { test, expect } = require("@playwright/test");
const { execFileSync } = require("node:child_process");

// Behaviour-driven coverage of the operations console + event-log panel. Drives
// the real app (Wisp serving the Lustre SPA) against a seeded PG19, asserting
// only what the user sees: the operation they pick, the board re-rendering to
// reflect the write, the journal row that records it, and the rejection message
// when the database refuses a fact — never CSS classes, ids, or DOM structure.
//
// The console submits each operation as a typed command to POST /api/operations;
// on success the board refetches for the slider's current date and the event log
// refreshes. We anchor every assertion to the seed's fixed dates and engineers,
// not the wall clock.
//
//   2026-06-15 = day 20619 (seed "now"; the board boots here)
//
// Seeded facts this suite leans on (003_seed.sql):
//   * Priya Sharma (engineer 1) is L5 throughout and on Ledger Migration +
//     Inventory Sync at 50% each; at the seed now she charges $1200/day.
//   * Aisha Okafor (engineer 3) is employed only from 2025-01-01, so an
//     allocation that starts before then dangles outside her employment.
const DAY = {
  "2026-06-15": "20619",
  "2026-12-31": "20818", // the slider's far end, past today's wall clock
};

// Move the slider to a fixed seed day index and wait for the board to re-render
// for that date (the "As of YYYY-MM-DD" heading is the visible confirmation).
async function scrubTo(page, isoDate) {
  await page.getByLabel("Board date").fill(DAY[isoDate]);
  await expect(
    page.getByRole("heading", { name: `As of ${isoDate}` }),
  ).toBeVisible();
}

// A regex matching the single visible board line for one engagement: the
// engineer name, then (anywhere after it on the same line) the expected fragment
// — their level, project sentence, or charge rate. Asserts only the text the user
// reads, with no reference to the tag/class/id carrying it.
function boardLine(name, fragment) {
  const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`${escape(name)}.*${escape(fragment)}`);
}

// The operations console region — every console interaction is scoped here so its
// fields (notably the "Engineer" roster select) never collide with the same-named
// timesheet selector elsewhere on the page.
function consolePanel(page) {
  return page.getByRole("region", { name: "Operations console" });
}

// Pick an operation in the console by its visible label (the option text).
async function selectOperation(page, label) {
  await consolePanel(page).getByLabel("Operation").selectOption({ label });
}

// Choose an option by visible name in one of the console's name selects (engineer,
// project, level): the user selects entities by name, not by typing an id.
async function selectField(page, label, optionLabel) {
  await consolePanel(page)
    .getByLabel(label)
    .selectOption({ label: optionLabel });
}

// Fill one console text input, found by its visible field label.
async function fillField(page, label, value) {
  await consolePanel(page).getByLabel(label).fill(value);
}

// Apply the composed operation.
async function applyOperation(page) {
  await consolePanel(page).getByRole("button", { name: "Apply operation" }).click();
}

// Restore engineer 1's (Priya's) role to the pristine seed regardless of test
// outcome: the promote split her single L5 row, so delete her role rows and
// re-insert the one seeded L5 span. Then clear only this test's journal row (the
// console-applied promote), leaving the seed's founding history intact — and FK-safe
// because her role rows (which referenced that entry) are already gone. Connects over
// TCP with psql using the same env-var defaults as the server (context.gleam), so the
// same cleanup works for the local Docker container and CI alike.
function restorePriyaRoleAndJournal() {
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
      "DELETE FROM engineer_role WHERE engineer_id = 1; " +
        "INSERT INTO engineer_role (engineer_id, level, held_during) " +
        "VALUES (1, 5, daterange('2024-01-01', '2027-01-01')); " +
        "DELETE FROM event_log WHERE actor = 'console' AND operation = 'promote';",
    ],
    { env: { ...env, PGPASSWORD: env.TEMPO_DB_PASSWORD ?? "tempo" } },
  );
}

test.beforeEach(async ({ page }) => {
  await page.goto("/");
  // The app boots at the seed "now" and shows the board for it.
  await expect(
    page.getByRole("heading", { name: "As of 2026-06-15" }),
  ).toBeVisible();
});

test("promoting an engineer re-renders the board with the new level and charge rate, and records it in the event log", async ({
  page,
}) => {
  // Before the promotion, at the seed now Priya is L5 on Ledger Migration at
  // $1200/day. We promote her to L6 effective before "now" and watch the board
  // re-render to L6 / $1800/day (the L6 rate) and the journal gain the entry.
  await scrubTo(page, "2026-06-15");
  await expect(
    page.getByText(
      boardLine("Priya Sharma", "Ledger Migration for Northwind Trading (50%, $1200/day)"),
    ),
  ).toBeVisible();
  // The journal opens on the seed's founding history (onboards, contracts, …);
  // the promotion we are about to apply is not among it yet.
  await expect(
    page.getByText("Promote engineer 1 to L6 from 2026-06-01", { exact: true }),
  ).toHaveCount(0);

  try {
    // Compose the promotion in the console: Priya (engineer 1) to L6 from
    // 2026-06-01 — before the visible board date, so it is in effect now.
    await selectOperation(page, "Promote");
    await selectField(page, "Engineer", "Priya Sharma");
    await selectField(page, "Level", "L6");
    await fillField(page, "Effective", "2026-06-01");
    await applyOperation(page);

    // The board refetched for the current date now reads the new level AND the
    // new charge rate on Priya's Ledger line. The level ("L6") precedes the
    // engagement sentence on the row, so this single line carries both — and the
    // "Ledger Migration" fragment scopes it to her Ledger engagement, not the
    // Inventory one (so the locator resolves to exactly one line).
    await expect(
      page.getByText(
        /Priya Sharma.*L6.*Ledger Migration for Northwind Trading \(50%, \$1800\/day\)/,
      ),
    ).toBeVisible();
    // The old $1200/day rate is gone from her Ledger line.
    await expect(
      page.getByText(
        boardLine("Priya Sharma", "Ledger Migration for Northwind Trading (50%, $1200/day)"),
      ),
    ).toHaveCount(0);

    // The journal records SYSTEM time — when the operation was applied (now) — so
    // it surfaces only once the slider reaches that point. Scrub to the far end of
    // the range (past today) and the event-log panel shows the operation's human
    // summary as a journal entry (newest-first). Matched exactly so it resolves to
    // the journal row and not the console's longer "Applied promote: …"
    // confirmation line, which embeds the same summary as a substring.
    await scrubTo(page, "2026-12-31");
    await expect(
      page.getByText("Promote engineer 1 to L6 from 2026-06-01", {
        exact: true,
      }),
    ).toBeVisible();
    await expect(page.getByText("No operations recorded yet.")).toHaveCount(0);
  } finally {
    restorePriyaRoleAndJournal();
  }
});

test("an operation the database refuses shows the user why it was rejected and leaves the board unchanged", async ({
  page,
}) => {
  // Containment integrity is enforced at the database: assigning Aisha (engineer
  // 3, employed only from 2025-01-01) to a project over a window that begins
  // before her employment would place the allocation outside its containing
  // employment. The server rejects it and the console surfaces the typed reason.
  await scrubTo(page, "2026-06-15");
  await expect(
    page.getByText(boardLine("Aisha Okafor", "On leave: annual")),
  ).toBeVisible();

  await selectOperation(page, "Assign to project");
  await selectField(page, "Engineer", "Aisha Okafor");
  await selectField(page, "Project", "Ledger Migration");
  await fillField(page, "Fraction", "0.5");
  await fillField(page, "Valid from", "2024-01-01");
  await fillField(page, "Valid to", "2024-06-01");
  await applyOperation(page);

  // The user sees a clear rejection naming the containment rule that fired —
  // not a crash, and not a silent success.
  await expect(page.getByText("Rejected:")).toBeVisible();
  await expect(
    page.getByText(/outside its containing fact/),
  ).toBeVisible();

  // The rejected write rolled back: the board still reads the seed (Aisha on
  // leave at the seed now) and no journal entry was recorded for the attempt.
  await expect(
    page.getByText(boardLine("Aisha Okafor", "On leave: annual")),
  ).toBeVisible();
  await expect(
    page.getByText(/Assign engineer 3 to project 100/),
  ).toHaveCount(0);
});
