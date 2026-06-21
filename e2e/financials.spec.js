const { test, expect } = require("@playwright/test");
const {
  signInAs,
  navigateTo,
  scrubTo,
  visibleInvoiceIds,
  invoiceRowById,
  clickContent,
  confirmOp,
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
