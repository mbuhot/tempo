const { test, expect } = require("@playwright/test");
const { execFileSync } = require("node:child_process");

// Behaviour-driven coverage of the Financials view (PRD-financials §6). Drives the
// real app (Wisp serving the Lustre SPA) against a seeded PG19, asserting only what
// the user sees: the invoice the user drafts, its status as-of the slider date, the
// total it carries, the action offered for that status, and the P&L revenue it
// produces once issued — never CSS classes, ids, or DOM structure — so the suite is
// robust to markup changes.
//
// Determinism: the day comes from the slider, whose value is a unix-day index, so
// we drive it to FIXED absolute seed dates rather than the wall clock. The board's
// "As of YYYY-MM-DD" heading (an <h2>) is the visible confirmation a scrub landed;
// the Financials panel re-reads for the same date.
//
//   2026-06-01 = day 20605  (before the issue date — the invoice reads `draft`)
//   2026-06-15 = day 20619  (seed "now"; we draft + issue here)
//
// Seeded facts this suite leans on (003_seed.sql + 012_financials.sql):
//   * Data Platform (project 300) for Globex Corporation: Marcus L4 @1000 × 30 +
//     Aisha L6 @1800 × 30 = $84,000 billed at the contract-agreed (2025) rates.
//   * No invoices/payroll exist in the canonical seed, so the spec owns exactly the
//     rows it creates and restores them afterward.
const DAY = {
  "2026-06-01": "20605",
  "2026-06-15": "20619",
};

// The single project this spec drafts an invoice for, and its expected billed total
// (Marcus 30000 + Aisha 54000, at the agreed 2025 rate card).
const PROJECT = { id: 300, name: "Data Platform", total: "$84,000" };

// Move the slider to a fixed seed day index and wait for the board to re-render for
// that date — the "As of YYYY-MM-DD" board heading is the visible confirmation, and
// resolves uniquely to the board (the Financials panel's own "As of …" is a
// paragraph, not a heading).
async function scrubTo(page, isoDate) {
  await page.getByLabel("Board date").fill(DAY[isoDate]);
  await expect(
    page.getByRole("heading", { name: `As of ${isoDate}` }),
  ).toBeVisible();
}

// The invoices table row for a project, scoped to the Invoices table so a project
// name appearing elsewhere (the Draft selector, the board) cannot match. Asserts
// only the visible text in the row, not the tag/class/id carrying it.
function invoiceRow(page, projectName) {
  return page
    .locator("table.invoices-table tbody tr")
    .filter({ hasText: projectName });
}

// The P&L "Revenue" row's Month cell text, read from the totals table. Scoped to the
// Revenue row so it cannot collide with the Cost/Profit rows.
function pnlMonthRevenue(page) {
  return page
    .locator("table.pnl-totals tbody tr")
    .filter({ hasText: "Revenue" });
}

// Remove every row this spec creates for the billed project — the invoice and its
// status/line children, the payroll rows, and the journal entries the unified
// operations write path appends — restoring the canonical seed (empty journal
// included) regardless of test outcome. Connects over TCP with psql using the same
// env-var defaults as the server (context.gleam), so the same cleanup works for the
// local Docker container and CI alike — no dependency on a container name.
function restoreSeed() {
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
      `DELETE FROM invoice_line WHERE invoice_id IN (SELECT id FROM invoice WHERE project_id=${PROJECT.id}); ` +
        `DELETE FROM invoice_status WHERE invoice_id IN (SELECT id FROM invoice WHERE project_id=${PROJECT.id}); ` +
        `DELETE FROM invoice WHERE project_id=${PROJECT.id}; ` +
        `DELETE FROM payroll_line; DELETE FROM payroll_run; ` +
        `DELETE FROM event_log WHERE operation IN ('draft_invoice','issue_invoice','pay_invoice','run_payroll');`,
    ],
    { env: { ...env, PGPASSWORD: env.TEMPO_DB_PASSWORD ?? "tempo" } },
  );
}

test.beforeEach(async ({ page }) => {
  await page.goto("/");
  // The app boots at the seed "now" with the board shown for it.
  await expect(
    page.getByRole("heading", { name: "As of 2026-06-15" }),
  ).toBeVisible();
  // The canonical seed has no invoices, so the Financials panel opens empty.
  await expect(page.getByText("No invoices as of this date.")).toBeVisible();
});

test.afterEach(() => {
  restoreSeed();
});

test("drafting then issuing an invoice moves it to issued and its total appears in the P&L revenue", async ({
  page,
}) => {
  // The financial write path end to end: draft an invoice for Data Platform's June
  // month, see it as `draft`, issue it, see it become `issued`, and watch its
  // $84,000 land in the month's P&L revenue (revenue is recognized on issue).
  await scrubTo(page, "2026-06-15");

  // Draft the invoice for Data Platform over the slider's month.
  await page.getByLabel("Project").selectOption({ label: PROJECT.name });
  await page.getByRole("button", { name: "Draft invoice" }).click();

  // It appears in the invoices table with its agreed-rate total, in `draft`, and
  // offers the Issue action (not Pay, not Paid).
  const row = invoiceRow(page, PROJECT.name);
  await expect(row).toContainText("Globex Corporation");
  await expect(row).toContainText(PROJECT.total);
  await expect(row).toContainText("draft");
  await expect(row.getByRole("button", { name: "Issue" })).toBeVisible();

  // Before issue, no revenue is recognized for the month (the only invoice is a
  // draft).
  await expect(pnlMonthRevenue(page)).toContainText("$0");

  // Issue it (transition draft -> issued at the slider date, 2026-06-15).
  await row.getByRole("button", { name: "Issue" }).click();

  // The row now reads `issued` and offers Pay; the draft action is gone.
  await expect(row).toContainText("issued");
  await expect(row.getByRole("button", { name: "Pay" })).toBeVisible();
  await expect(row.getByRole("button", { name: "Issue" })).toHaveCount(0);

  // The issued invoice's total is now recognized as the month's revenue.
  await expect(pnlMonthRevenue(page)).toContainText(PROJECT.total);
});

test("scrubbing the slider before the issue date shows the invoice as draft", async ({
  page,
}) => {
  // FR-F4: an invoice's status is a temporal fact. Draft on 2026-06-15 and issue it
  // there, then scrub the slider back to 2026-06-01 — before the issue date — and
  // the same invoice reads `draft` again, offering Issue rather than Pay.
  await scrubTo(page, "2026-06-15");
  await page.getByLabel("Project").selectOption({ label: PROJECT.name });
  await page.getByRole("button", { name: "Draft invoice" }).click();

  const row = invoiceRow(page, PROJECT.name);
  await expect(row).toContainText("draft");
  await row.getByRole("button", { name: "Issue" }).click();
  await expect(row).toContainText("issued");

  // Scrub the slider back to before the issue date: the invoices table shows the
  // invoice's status AS OF that earlier date as `draft` — the issue had not
  // happened yet — and so offers Issue rather than Pay. The same invoice reads a
  // different lifecycle state at a different instant.
  await scrubTo(page, "2026-06-01");
  const earlierRow = invoiceRow(page, PROJECT.name);
  await expect(earlierRow).toContainText("draft");
  await expect(earlierRow.getByRole("button", { name: "Issue" })).toBeVisible();
  await expect(earlierRow.getByRole("button", { name: "Pay" })).toHaveCount(0);
});
