const { test, expect } = require("@playwright/test");
const { signInAs, navigateTo, scrubTo } = require("./helpers");

// Behaviour-driven coverage of the generic data table on the Invoices list: the
// server advertises the schema (columns, filters, sort), and the client renders and
// drives it. We assert only what the user sees and does — rows narrowing under a
// filter, the top row changing under a sort, more rows appearing on "Load more", and
// a hidden column staying hidden across a reload — never CSS classes or DOM
// internals. Runs against the demo financials seed (18 invoices, Jan–Mar paid,
// Apr–May issued, Jun draft) at the seed-now rail date.

test.beforeEach(async ({ page }) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Finance");
  await expect(page.getByRole("heading", { name: "Finance" })).toBeVisible();
  await scrubTo(page, "2026-06-15");
  // The invoices table has landed once its pinned "#" header is on screen.
  await expect(page.getByRole("columnheader", { name: "#" })).toBeVisible();
});

test("filtering by status narrows the invoices to that status", async ({
  page,
}) => {
  // June invoices are drafts, so a Draft status pill is on screen to start.
  await expect(
    page.getByRole("cell", { name: "Draft", exact: true }).first(),
  ).toBeVisible();

  // Open the Status filter and choose Paid: the table re-queries and now shows only
  // paid invoices — no Draft or Issued status remains.
  await page.getByRole("button", { name: "Status" }).click();
  await page.getByRole("checkbox", { name: "Paid" }).check();

  await expect(
    page.getByRole("cell", { name: "Paid", exact: true }).first(),
  ).toBeVisible();
  await expect(
    page.getByRole("cell", { name: "Draft", exact: true }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("cell", { name: "Issued", exact: true }),
  ).toHaveCount(0);
});

test("sorting by the # column brings the oldest invoice to the top", async ({
  page,
}) => {
  // The default sort is newest-billing-first, so the top row is a recent (June)
  // invoice. The seed mints invoice ids chronologically, so sorting ascending by #
  // brings the lowest-id — earliest-billed (January) — invoice to the top. We assert
  // the top row's billing month flips June -> January, without depending on the
  // absolute id value (which varies by database history).
  await expect(page.getByRole("row").nth(1)).toContainText("Jun 2026");

  await page.getByRole("columnheader", { name: "#" }).click();

  await expect(page.getByRole("row").nth(1)).toContainText("Jan 2026");
});

test("scrolling to the bottom loads more invoice rows (infinite scroll)", async ({
  page,
}) => {
  // The first page is a bounded slice; the seed has more invoices than fit, so
  // scrolling the last loaded row into view loads the next page and grows the table.
  // Retry the scroll: a scroll can land while the page is still appending.
  const before = await page.getByRole("row").count();
  await expect(async () => {
    await page.getByRole("row").last().scrollIntoViewIfNeeded();
    expect(await page.getByRole("row").count()).toBeGreaterThan(before);
  }).toPass();
});

test("hiding a column persists across a reload", async ({ page }) => {
  // The Client column is shown to start.
  await expect(
    page.getByRole("columnheader", { name: "Client" }),
  ).toBeVisible();

  // Hide it via the Columns manager: the header disappears at once.
  await page.getByRole("button", { name: "Columns" }).click();
  await page.getByRole("checkbox", { name: "Client" }).uncheck();
  await expect(
    page.getByRole("columnheader", { name: "Client" }),
  ).toHaveCount(0);

  // The choice is a saved per-user preference: after a full reload the table comes
  // back with Client still hidden.
  await page.reload();
  await expect(page.getByRole("columnheader", { name: "#" })).toBeVisible();
  await expect(
    page.getByRole("columnheader", { name: "Client" }),
  ).toHaveCount(0);
});
