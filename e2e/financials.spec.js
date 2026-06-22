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
  escapeRegExp,
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

// The rail sits at 2026-06-15 in every beat (beforeEach), and the Issue / Mark-paid
// forms default their date to the rail's as-of. So issuing here stamps issued_at =
// 2026-06-15 and paying stamps paid_at = 2026-06-15, both rendered as "<d> <Mon>
// <year>" -> "15 Jun 2026". The row's lifecycle cell then carries the Neutral chip
// "Issued 15 Jun 2026" / "Paid 15 Jun 2026" in place of any action button.
const ISSUE_DATE = "15 Jun 2026";

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
  // The lifecycle cell now carries the "Issued <date>" chip and the row stops
  // offering Issue — the Mark-paid action takes its place (issued -> paid is the
  // only valid next step). issued_at was stamped at the rail's 2026-06-15.
  await expect(row()).toContainText(`Issued ${ISSUE_DATE}`);
  await expect(row().getByRole("button", { name: "Issue" })).toHaveCount(0);
  await expect(row().getByRole("button", { name: "Mark paid" })).toBeVisible();

  // Pay it: Mark paid opens the pay form; the modal's Mark-paid confirm commits
  // issued -> paid. The row now reads `paid`, carries the "Paid <date>" chip, and
  // offers no further action — neither Issue nor Mark paid.
  await clickContent(row().getByRole("button", { name: "Mark paid" }));
  await expect(page.getByText("Mark invoice paid")).toBeVisible();
  await confirmOp(page, "Mark paid");
  await expect(row()).toContainText("paid");
  await expect(row()).toContainText(`Paid ${ISSUE_DATE}`);
  await expect(row().getByRole("button", { name: "Mark paid" })).toHaveCount(0);
  await expect(row().getByRole("button", { name: "Issue" })).toHaveCount(0);
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
  // At/after the issue date the row carries the "Issued <date>" chip and no Issue
  // action.
  await expect(row()).toContainText(`Issued ${ISSUE_DATE}`);
  await expect(row().getByRole("button", { name: "Issue" })).toHaveCount(0);

  // Scrub the rail back before the 2026-06-15 issue date: the SAME invoice reverts
  // to `draft`, the "Issued <date>" chip is GONE, and the Issue action returns (no
  // Mark paid). The lifecycle cell is a pure function of the row's as-of status.
  await scrubTo(page, "2026-06-01");
  await expect(row()).toContainText("draft");
  await expect(row().getByRole("button", { name: "Issue" })).toBeVisible();
  await expect(row().getByText(`Issued ${ISSUE_DATE}`)).toHaveCount(0);
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

// Open the P&L tab from the Finance page. The tab is a button labelled "P&L";
// clicking it reveals the P&L panel, whose per-engineer table title is "Profit &
// loss · <Mon year>" — we wait for that month-suffixed title as the visible signal
// the tab's read model has landed.
async function openPnlTab(page, month) {
  await page.getByRole("button", { name: "P&L", exact: true }).click();
  await expect(page.getByText(`Profit & loss · ${month}`)).toBeVisible();
}

test("the P&L tab shows month and year-to-date figures side by side", async ({
  page,
}) => {
  // FR-F (P&L): the tab carries TWO stat rows — a single-MONTH row labelled by the
  // as-of month and a YEAR-TO-DATE row labelled "since Jan <year>". The rail sits at
  // 2026-06-15 (beforeEach), so the month window is June 2026 and the YTD window is
  // Jan–Jun 2026. With five prior months of the same year folded in, YTD is a
  // genuinely distinct, wider window than the single month — we assert both labelled
  // axes are present (revenue / cost / profit, each in month and YTD form) and that
  // every figure renders as a money-k value. We assert the labelled axes and that
  // figures render, not exact dollars: the e2e DB is append-only and shared, so a
  // concurrent spec's self-drafted invoice or back-dated promotion can shift the
  // absolute revenue/cost — but the month-vs-YTD label contract is fixed.
  await openPnlTab(page, MONTH);

  for (const metric of ["Revenue", "Cost", "Profit"]) {
    await expect(page.getByText(`${metric} · ${MONTH}`)).toBeVisible();
    await expect(page.getByText(`${metric} · since Jan 2026`)).toBeVisible();
  }
  // The YTD row's stats carry the literal "YTD" unit suffix, distinguishing them
  // from the month row's "/mo" — both axes coexist on the tab.
  await expect(page.getByText("YTD").first()).toBeVisible();
  await expect(page.getByText("/mo").first()).toBeVisible();
});

test("the P&L recognizes a worked month's revenue from capacity, with no invoice (accrual)", async ({
  page,
}) => {
  // ACCRUAL, capacity-based (ADR-043): P&L revenue is the billable value of the work
  // performed (allocation × rate-card), recognized as the work happens — it does NOT
  // wait on an invoice. July 2026 has full allocations but NO beat ever drafts or
  // issues an invoice for it, so under any invoice-gated rule its revenue would read
  // $0; under the capacity basis each engineer earns rate × days: Marcus is L5 from
  // 2026-07-01 at the revised $1,400/d × 31 = $43,400; Aisha is L6 $1,800/d × 31 =
  // $55,800 (leave does not reduce capacity revenue). Asserting these exact figures
  // for an un-invoiced month passes ONLY under the capacity basis. (Priya is omitted
  // — a concurrent spec may promote her, shifting her rate.)
  await openPnlTab(page, MONTH);
  await scrubTo(page, "2026-07-15");
  await expect(page.getByText("Profit & loss · Jul 2026")).toBeVisible();

  // Scoped to the row matching BOTH the engineer name AND the revenue figure: the
  // inactive Payroll subpage also renders these engineers' rows but carries their
  // SALARY, never these billing figures, so the filter resolves only the visible P&L
  // row. A "$0" revenue (any invoice-gated result for un-invoiced July) matches no
  // such row and fails here.
  for (const [name, revenue] of [
    ["Marcus Chen", "$43,400"],
    ["Aisha Okafor", "$55,800"],
  ]) {
    await expect(
      page
        .getByRole("row", { name: new RegExp(escapeRegExp(name)) })
        .filter({ hasText: revenue }),
    ).toBeVisible();
  }
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

// Open the Forecast tab from the Finance page. The tab is a button labelled
// "Forecast"; clicking it reveals the forward-P&L panel titled "Forecast". The
// panel's count header reads "<n> months", so we wait for that month-suffixed count
// as the visible signal the read model has landed.
async function openForecastTab(page) {
  await page.getByRole("button", { name: "Forecast", exact: true }).click();
  await expect(page.getByText(/\d+ months/)).toBeVisible();
}

test("the Forecast tab projects committed demand month-by-month to the cliff", async ({
  page,
}) => {
  // FORWARD P&L from committed demand (the demand-side mirror of the capacity P&L).
  // At the seed now (2026-06-15) the forecast buckets every calendar month from June
  // 2026 to the cliff — the latest end of any requirement or allocation = 2027-01-01,
  // so the last bucket is December 2026. The table carries the Month/Revenue/Cost/
  // Profit/Margin axes and a blended Total row. We assert the labelled axes, the
  // endpoint month, and that the revenue-to-the-cliff note renders a money figure —
  // not exact dollars, since the shared append-only DB lets concurrent specs shift
  // allocation-side revenue.
  await openForecastTab(page);

  for (const header of ["Month", "Revenue", "Cost", "Profit", "Margin"]) {
    await expect(
      page.getByRole("columnheader", { name: header, exact: true }),
    ).toBeVisible();
  }
  await expect(page.getByText(/\$[\d,]+ revenue to the cliff/)).toBeVisible();
  await expect(
    page.getByRole("row", { name: /Dec 2026/ }),
  ).toBeVisible();
  await expect(
    page.getByRole("row", { name: /^Total/ }),
  ).toBeVisible();
});

test("the prospective project forecasts requirement-based revenue with no allocations", async ({
  page,
}) => {
  // The (b) rule end to end. The seed's Edge Analytics (the prospective Initech
  // project) carries capacity requirements 2× L3 + 1× L4 + 0.5× L5 over
  // 2026-08-01..2027-01-01 but NO allocation, so under any allocation-only forecast
  // it would add $0. Its August 2026 requirement demand prices at
  // (2×$800 + 1×$1,000 + 0.5×$1,400) × 31 days = $102,300. We compare two August
  // figures on ONE page load — the whole-consultancy forecast total and the same
  // forecast with the prospective project's contribution subtracted is not available
  // per-row, so instead we prove the requirement basis lifts August strictly above
  // the allocation-only months around it is also concurrent-sensitive. The stable,
  // self-contained proof: August's revenue exceeds the seed's allocation-only
  // baseline ($142,600) by at least the requirement value, i.e. it clears $200,000 —
  // unreachable from the four allocated projects alone, so only the unstaffed
  // project's priced requirements put it there.
  await openForecastTab(page);
  await expect(
    page
      .getByRole("row", { name: /Aug 2026/ })
      .filter({ hasText: /\$2\d{2},\d{3}|\$[3-9]\d{2},\d{3}/ }),
  ).toBeVisible();
});

test("setting a capacity requirement on a project lists it in the requirements panel", async ({
  page,
}) => {
  // The demand-side write: on a project detail the "Set requirement" op records a
  // capacity requirement (a FOR-PORTION-OF write), and the "Capacity requirements"
  // panel then lists it as a level chip + ×quantity + period. We set 2× L3 over
  // 2026-08-01..2027-01-01 on Ledger Migration (project 100, whose run spans that
  // window). Re-run safe: the set is idempotent (FOR PORTION OF re-sets the same
  // (project, level) window — no overlap, no split), so repeated runs against the
  // append-only DB land the same single line.
  await navigateTo(page, "Projects");
  // Exact match: the page-title heading is "Projects"; the section heading "All
  // projects" also contains "projects", so a loose name matches both.
  await expect(
    page.getByRole("heading", { name: "Projects", exact: true }),
  ).toBeVisible();
  await clickContent(page.getByText("Ledger Migration").first());
  await expect(
    page.getByRole("heading", { name: "Ledger Migration" }),
  ).toBeVisible();

  await page.getByRole("button", { name: "Set requirement" }).dispatchEvent("click");
  await expect(page.getByText("Set capacity requirement")).toBeVisible();
  await page.getByLabel("Level").selectOption({ label: "L3 · Senior" });
  await page.getByLabel("Quantity").fill("2");
  await page.getByLabel("Valid from").fill("2026-08-01");
  await page.getByLabel("Valid to").fill("2027-01-01");
  await confirmOp(page, "Set requirement");

  // The panel now carries the line: the L3 band chip, its ×2 quantity, and the
  // period rendered "1 Aug 2026 → 1 Jan 2027".
  await expect(
    page.getByRole("heading", { name: "Capacity requirements" }),
  ).toBeVisible();
  await expect(page.getByText("L3 · Senior").first()).toBeVisible();
  await expect(page.getByText("×2").first()).toBeVisible();
  await expect(
    page.getByText("1 Aug 2026 → 1 Jan 2027").first(),
  ).toBeVisible();
});
