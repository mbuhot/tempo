const { test, expect } = require("@playwright/test");
const { signInAs, navigateTo, clickContent, confirmOp, opModal } = require("./helpers");

// Behaviour-driven coverage of the project-detail Capability coverage tab (#39):
// the demand-vs-team read (a bar per requirement, gap-highlighted, with covering
// engineers named) and the Set-requirement write that records new demand. We
// assert only what the user sees — bar/count text, engineer chips, journal
// text — never CSS classes, ids, or DOM structure.
//
// The event log and facts are APPEND-ONLY and never reset between runs, so the
// write test is re-run safe: it sets a project's capability requirement on a
// capability the seed never touches (Data Engineering, target L2 x1) over a
// FIXED past window (2026-02-01..2026-08-01) that lies inside Ledger Migration's
// project run — re-stating the identical window is an idempotent
// FOR-PORTION-OF replace, and the journal match is a substring (≥1), never a
// count.

async function openLedgerMigration(page) {
  await navigateTo(page, "Projects");
  await clickContent(page.getByText("Ledger Migration").first());
  await expect(page.getByRole("heading", { name: "Ledger Migration" })).toBeVisible();
}

async function openCoverageTab(page) {
  await page.getByRole("button", { name: "Capability coverage" }).click();
  await expect(page.getByRole("heading", { name: "Capability coverage" })).toBeVisible();
}

// The Coverage tab's panel, scoped so its "Set requirement" launcher never
// collides with the Overview tab's capacity-requirements panel, which shares
// the same launcher label and stays in the DOM (hidden, not removed) behind
// the tab switch.
function coveragePanel(page) {
  return page.locator(".panel", { hasText: "Capability coverage" });
}

test("the Capability coverage tab renders the seeded gap and the fully-covered contrast", async ({
  page,
}) => {
  // Ledger Migration's seeded demand (#39 seed): Payments Platform needs 2
  // engineers at L3, but only Priya is allocated and covers it alone, leaving a
  // visible gap of one; Frontend Delivery needs 1 at L1 and Priya's rollup
  // clears it, so it is fully covered.
  await signInAs(page, "Admin");
  await openLedgerMigration(page);
  await openCoverageTab(page);

  const paymentsPlatform = page.locator(".coverage__row", {
    hasText: "Payments Platform",
  });
  await expect(
    paymentsPlatform.getByText("1 / 2 · gap 1", { exact: true }),
  ).toBeVisible();
  await expect(
    paymentsPlatform.getByText("Priya Sharma · 3.6 · 50%", { exact: true }),
  ).toBeVisible();

  const frontendDelivery = page.locator(".coverage__row", {
    hasText: "Frontend Delivery",
  });
  await expect(
    frontendDelivery.getByText("1 / 1 · covered", { exact: true }),
  ).toBeVisible();
  await expect(
    frontendDelivery.getByText("Priya Sharma · 1.5 · 50%", { exact: true }),
  ).toBeVisible();
});

test("setting a capability requirement records new demand and is journalled", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await openLedgerMigration(page);
  await openCoverageTab(page);

  await coveragePanel(page)
    .getByRole("button", { name: "Set requirement" })
    .dispatchEvent("click");
  await expect(page.getByLabel("Capability")).toBeVisible();
  await page.getByLabel("Capability").selectOption({ label: "Data Engineering" });
  await page.getByLabel("Target level").selectOption("2");
  await page.getByLabel("Quantity").fill("1");
  await page.getByLabel("Valid from").fill("2026-02-01");
  await page.getByLabel("Valid to").fill("2026-08-01");
  await confirmOp(page, "Set requirement");

  await expect(opModal(page)).toHaveCount(0);
  const dataEngineering = page.locator(".coverage__row", {
    hasText: "Data Engineering",
  });
  await expect(dataEngineering).toBeVisible();

  await navigateTo(page, "Activity");
  await expect(
    page
      .getByText(
        "Set capability demand: 1.0x L2 capability 2 on project 100 over 2026-02-01..2026-08-01",
      )
      .first(),
  ).toBeVisible();
});
