const { test, expect } = require("@playwright/test");
const {
  signInAs,
  navigateTo,
  scrubTo,
  visibleInvoiceIds,
  invoiceRowById,
  clickContent,
  confirmOp,
  rosterRow,
} = require("./helpers");

// Behaviour-driven coverage of the Finance invoice lifecycle (PRD-financials §6) on
// the new shell: draft an invoice, issue it, see its temporal status flip as the
// rail moves, and pay it — each step a contextual op (Draft / Issue / Mark paid)
// posted to /api/operations. We assert only what the user sees in the invoices
// table row: its project, client, month, total, status, and the action offered for
// that status — never CSS classes, ids, or DOM structure.
//
// Idempotency: the database is append-only and never reset, so each draft creates a
// NEW invoice. We capture the id that appears after drafting (the one not present
// before) and scope every assertion to THAT invoice's row by its "#<id>" — never to
// counts, an empty table, or a "first row" — so repeated runs (which leave their
// issued/paid invoices behind) stay green.
//
// Data: Data Platform (project 300) for Globex Corporation bills Marcus (L4 @1000)
// + Aisha (L6 @1800) full-time over the 30-day June 2026 month at the agreed 2025
// rates = $84,000. June is before Marcus's 2026-07-01 promotion, so the total is
// stable.
const PROJECT = { id: 300, name: "Data Platform", client: "Globex Corporation" };
const TOTAL = "$84,000";
const MONTH = "Jun 2026";

// Draft an invoice for Data Platform's June 2026 month and return the id of the
// invoice that draft created (the one absent before it).
async function draftJuneInvoice(page) {
  // The invoice id is a monotonically increasing sequence, so the invoice this
  // draft creates is the one with the greatest id. Capture the current max, draft,
  // then poll until a larger id appears and return THAT id — captured the moment it
  // is observed, not re-read afterwards.
  //
  // The before-read must be of the SETTLED table: a refetch (from sign-in/nav/scrub
  // in beforeEach) momentarily clears the table to a Loading placeholder, which a
  // single read would see as zero invoices. Were maxBefore 0 while an older paid
  // invoice actually exists, the post-draft poll would lock onto THAT stale invoice.
  // So we wait for the max to stabilise (two equal consecutive reads) before drafting.
  const maxBefore = await settledMaxInvoiceId(page);
  await page.getByRole("button", { name: "+ Draft" }).dispatchEvent("click");
  await expect(page.getByText("Draft an invoice")).toBeVisible();
  await page.getByLabel("Project").selectOption({ label: PROJECT.name });
  await page.getByLabel("Billing from").fill("2026-06-01");
  await page.getByLabel("Billing to").fill("2026-07-01");
  await confirmOp(page, "Draft");
  let created = 0;
  await expect
    .poll(async () => {
      const max = await maxInvoiceId(page);
      if (max > maxBefore) created = max;
      return created;
    })
    .toBeGreaterThan(maxBefore);
  return created;
}

async function maxInvoiceId(page) {
  const ids = await visibleInvoiceIds(page);
  return ids.size === 0 ? 0 : Math.max(...ids);
}

// The greatest visible invoice id, read only once the invoices table has settled:
// poll until two consecutive reads agree, so a transient Loading re-render (which
// momentarily shows zero invoices) cannot be mistaken for an empty ledger.
async function settledMaxInvoiceId(page) {
  let previous = -1;
  let settled = 0;
  await expect
    .poll(async () => {
      const max = await maxInvoiceId(page);
      const stable = max === previous;
      previous = max;
      if (stable) settled = max;
      return stable;
    })
    .toBe(true);
  return settled;
}

test.beforeEach(async ({ page }) => {
  await signInAs(page, "Marcus Chen");
  await navigateTo(page, "Finance");
  await expect(page.getByRole("heading", { name: "Finance" })).toBeVisible();
  await scrubTo(page, "2026-06-15");
});

test("drafting then issuing then paying walks an invoice through its lifecycle", async ({
  page,
}) => {
  // Draft the June invoice; the new row reads its agreed-rate total in `draft` and
  // offers the Issue action.
  const id = await draftJuneInvoice(page);
  const row = () => invoiceRowById(page, id);
  await expect(row()).toContainText(PROJECT.name);
  await expect(row()).toContainText(PROJECT.client);
  await expect(row()).toContainText(MONTH);
  await expect(row()).toContainText(TOTAL);
  await expect(row()).toContainText("draft");
  await expect(row().getByRole("button", { name: "Issue" })).toBeVisible();

  // Issue it: the row's Issue opens the Issue form (invoice id prefilled, date
  // defaulted to the rail's 2026-06-15); Apply commits the draft -> issued
  // transition. The row now reads `issued` and offers "Mark paid".
  await clickContent(row().getByRole("button", { name: "Issue" }));
  await expect(page.getByText("Issue invoice")).toBeVisible();
  await confirmOp(page, "Issue");
  await expect(row()).toContainText("issued");
  await expect(row().getByRole("button", { name: "Mark paid" })).toBeVisible();
  await expect(row().getByRole("button", { name: "Issue" })).toHaveCount(0);

  // Pay it: Mark paid opens the pay form; the modal's Mark-paid confirm commits
  // issued -> paid. The row now reads `paid` and offers no further action.
  await clickContent(row().getByRole("button", { name: "Mark paid" }));
  await expect(page.getByText("Mark invoice paid")).toBeVisible();
  await confirmOp(page, "Mark paid");
  await expect(row()).toContainText("paid");
  await expect(row().getByRole("button", { name: "Mark paid" })).toHaveCount(0);
});

test("an invoice's status is temporal: scrubbing before its issue date shows it as draft", async ({
  page,
}) => {
  // FR-F4: status is a temporal fact. Draft on 2026-06-15 and issue it there, then
  // scrub the rail back to 2026-06-01 — before the issue date — and the SAME
  // invoice reads `draft` again, offering Issue rather than Mark paid. The same
  // invoice carries a different lifecycle state at a different instant.
  const id = await draftJuneInvoice(page);
  const row = () => invoiceRowById(page, id);
  await expect(row()).toContainText("draft");

  await clickContent(row().getByRole("button", { name: "Issue" }));
  await expect(page.getByText("Issue invoice")).toBeVisible();
  await confirmOp(page, "Issue");
  await expect(row()).toContainText("issued");

  await scrubTo(page, "2026-06-01");
  await expect(row()).toContainText("draft");
  await expect(row().getByRole("button", { name: "Issue" })).toBeVisible();
  await expect(row().getByRole("button", { name: "Mark paid" })).toHaveCount(0);
});

// Open the Payroll tab from the Finance page. The tab is a button labelled
// "Payroll"; clicking it reveals the payroll panel. The panel's title flexes by
// state ("Payroll preview · <month>" un-run, "Payroll run · <month>" once run), so
// we wait for the state-agnostic month suffix rather than a fixed title.
async function openPayrollTab(page) {
  await page.getByRole("button", { name: "Payroll", exact: true }).click();
  await expect(page.getByText(/Payroll (preview|run) ·/)).toBeVisible();
}

// The three employed engineers, by visible name. Self-contained: they exist on the
// migrate-only e2e DB (base employment seed) with no financials seed.
const EMPLOYED = ["Priya Sharma", "Marcus Chen", "Aisha Okafor"];

// Run payroll for a month via the Run-payroll modal, if it has not been run yet.
// ENSURE-THEN-ASSERT, re-run-safe against the append-only DB and the
// payroll_period EXCLUDE-overlap constraint (a 2nd run of the same month is
// refused): the "Run payroll" button is present ONLY in the un-run preview state,
// so its presence is the signal a run is needed.
async function ensurePayrollRun(page, monthFrom, monthTo) {
  const runButton = page.getByRole("button", { name: "Run payroll", exact: true });
  const needsRun = await runButton.isVisible().catch(() => false);
  if (needsRun) {
    await runButton.click();
    await expect(page.getByText("Run payroll").first()).toBeVisible();
    await page.getByLabel("Period from").fill(monthFrom);
    await page.getByLabel("Period to").fill(monthTo);
    await confirmOp(page, "Run payroll");
  }
}

test("an un-run month previews the employed engineers as not-yet-run rather than zero-headcount", async ({
  page,
}) => {
  // STATE 1 (NOT YET RUN): the Payroll tab reads a materialized run, written only
  // by RunPayroll. October 2026 is never run in any test, so its panel must read
  // as an honest live PREVIEW — the "<n> employed · not yet run" pill and a
  // "<total> to pay" note — listing the three currently-employed engineers, NEVER
  // "0 employed".
  await openPayrollTab(page);
  await scrubTo(page, "2026-10-15");

  await expect(page.getByText("not yet run", { exact: false })).toBeVisible();
  await expect(page.getByText("3 employed", { exact: false })).toBeVisible();
  await expect(page.getByText("to pay", { exact: false })).toBeVisible();
  await expect(page.getByText("0 employed")).toHaveCount(0);
  for (const name of EMPLOYED) {
    await expect(page.getByRole("row", { name: new RegExp(name) })).toBeVisible();
  }
});

test("running payroll materializes the run and shows each engineer's paid amount", async ({
  page,
}) => {
  // STATE 2 (RUN): scrub to a future month (August 2026), run its payroll once, and
  // the panel flips from the live PREVIEW to a MATERIALIZED run — title "Payroll run
  // · Aug 2026", the "Run payroll" button gone, the "not yet run" framing gone, and
  // each employed engineer showing a PAID dollar amount. We assert the run/material-
  // isation transition, not reconciled-vs-variance: on the shared append-only DB a
  // concurrent spec's open-ended promotion (e.g. Priya → L6 from Jun 1) can back-date
  // a variance over any later month after its run, so "reconciled" is not stable here
  // — Beat 3 exercises the variance path deterministically instead.
  await openPayrollTab(page);
  await scrubTo(page, "2026-08-15");
  await ensurePayrollRun(page, "2026-08-01", "2026-08-31");

  await expect(page.getByText("Payroll run · Aug 2026", { exact: false })).toBeVisible();
  await expect(page.getByText("not yet run")).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Run payroll", exact: true }),
  ).toHaveCount(0);
  for (const name of EMPLOYED) {
    const row = page.getByRole("row", { name: new RegExp(name) });
    await expect(row).toBeVisible();
    await expect(row).toContainText(/\$[\d,]+/);
  }
});

test("back-dating a promotion into a run month surfaces the back-pay owed", async ({
  page,
}) => {
  // STATE 3 (RUN + VARIANCE): the bitemporal payoff. September 2026 is its OWN
  // run month — isolated from August's reconciled run so this promotion never
  // back-dates a variance into August (Aug is before Sep 1, so it stays reconciled
  // on re-runs). Run September's payroll (capturing Priya's then-current salary),
  // then back-date a promotion for Priya to L7 effective September 1. The frozen
  // paid line does not move, but the LIVE recompute rises to the L7 salary, so the
  // September panel now warns "⚠ <owed> back-pay owed" and Priya's row shows
  // "should be" > "paid" with a non-zero Δ.
  //
  // Re-run safe: ensurePayrollRun skips if September is already run; promoting
  // Priya to L7 from the same fixed date is idempotent (FOR PORTION OF re-sets the
  // same level — no overlap, no split). Promote to L7 (not L6) so the recompute
  // rises above paid regardless of whether other specs have already lifted her to
  // L6. Signed in as Marcus (the beforeEach actor), so Priya's detail heading never
  // collides with the sidebar's signed-in-user name.
  await openPayrollTab(page);
  await scrubTo(page, "2026-09-15");
  await ensurePayrollRun(page, "2026-09-01", "2026-09-30");

  await navigateTo(page, "People");
  await expect(page.getByRole("heading", { name: "People" })).toBeVisible();
  await clickContent(rosterRow(page, "Priya Sharma"));
  await expect(page.getByRole("heading", { name: /Priya Sharma/ })).toBeVisible();
  await page.getByRole("button", { name: "Promote" }).dispatchEvent("click");
  await expect(page.getByLabel("New level")).toBeVisible();
  await page.getByLabel("New level").fill("7");
  await page.getByLabel("Effective").fill("2026-09-01");
  await confirmOp(page, "Promote");
  await expect(page.getByText("L7 · Fellow").first()).toBeVisible();

  await navigateTo(page, "Finance");
  await openPayrollTab(page);
  await scrubTo(page, "2026-09-15");

  // The warning header carries a dollar owed amount, and Priya's row reads her L7
  // "should be" ($20,000 — a full September at the L7 salary) — strictly above
  // whatever was paid at her pre-promotion level, the visible back-pay correction.
  await expect(page.getByText(/⚠ \$[\d,]+ back-pay owed/)).toBeVisible();
  await expect(
    page.getByRole("row", { name: /Priya Sharma/ }),
  ).toContainText("$20,000");
});

test("a drafted invoice is journalled in the Activity log", async ({ page }) => {
  // Drafting posts an operation that the append-only journal records. Switch to
  // Activity, show "All time" (a fresh write is recorded on system time, today,
  // outside the default recent window), and the draft's summary is listed — matched
  // by its distinctive invoice id substring so repeated runs stay green.
  const id = await draftJuneInvoice(page);

  await navigateTo(page, "Activity");
  await expect(page.getByRole("heading", { name: "Activity" })).toBeVisible();
  await page.getByLabel("Quick range").selectOption({ label: "All time" });
  await expect(
    page
      .getByText(
        new RegExp(`Draft invoice for project ${PROJECT.id} \\(invoice ${id}\\)`),
      )
      .first(),
  ).toBeVisible();
});
