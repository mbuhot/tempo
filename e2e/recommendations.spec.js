const { test, expect } = require("@playwright/test");
const {
  signInAs,
  navigateTo,
  clickContent,
  scrubTo,
  opModal,
} = require("./helpers");

// Behaviour-driven coverage of the project-detail "Recommended assignments"
// panel (#40): the ranked candidate list against Ledger Migration's seeded
// Payments Platform gap (2 engineers at L3, only Priya on team — see
// coverage.spec.js), and the per-row Assign launcher that pre-fills the
// existing OpAssignToProject modal.
//
// The panel shows the top 4 ready-now candidates followed by ALL growth
// (mentorship) candidates, ranks continuing through the displayed order, so a
// deep ready-now bench never crowds the growth rows out of view: rank 1 Omar
// Haddad, 2 Mei Lin, 3 Sofia Rossi, 4 Tunde Okafor (ready-now), 5 Rohan
// Sharma, 6 Dmitri Volkov (growth, paired with an on-team L4 teacher).
//
// The event log and allocation rows are APPEND-ONLY and never reset between
// runs, so no test here may complete an actual Assign write — the prefill
// test opens the modal, asserts its pre-filled fields, then cancels.

async function openLedgerMigration(page) {
  await navigateTo(page, "Projects");
  await clickContent(page.getByText("Ledger Migration").first());
  await expect(page.getByRole("heading", { name: "Ledger Migration" })).toBeVisible();
}

async function openCoverageTab(page) {
  await page.getByRole("button", { name: "Capability coverage" }).click();
  await expect(page.getByRole("heading", { name: "Capability coverage" })).toBeVisible();
}

// The Recommended-assignments panel for the seeded Payments Platform gap,
// scoped by its badge text: coverage.spec.js's re-run-safe write test also
// leaves a standing Data Engineering demand on this same project, which
// renders its own same-titled "Recommended assignments" panel — the badge
// distinguishes them, and per-row "Assign" buttons stay clear of the page
// header's identically named "Assign" launcher.
function recommendationsPanel(page) {
  return page
    .getByRole("region", { name: "Recommended assignments" })
    .filter({ hasText: "Payments Platform gap" });
}

function recommendationRows(page) {
  return recommendationsPanel(page).locator("div.rec");
}

test("the Recommended assignments panel ranks ready-now candidates then growth pairings for the seeded gap (#40)", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await openLedgerMigration(page);
  await openCoverageTab(page);

  const panel = recommendationsPanel(page);
  await expect(
    panel.getByText("Payments Platform gap", { exact: true }),
  ).toBeVisible();

  const rows = recommendationRows(page);
  await expect(rows).toHaveCount(6);

  const readyNowNames = ["Omar Haddad", "Mei Lin", "Sofia Rossi", "Tunde Okafor"];
  for (const [zeroBasedIndex, name] of readyNowNames.entries()) {
    const row = rows.nth(zeroBasedIndex);
    await expect(row.locator(".rec__rank")).toHaveText(String(zeroBasedIndex + 1));
    await expect(row.locator(".rec__name")).toContainText(name);
  }

  const omarRow = rows.nth(0);
  await expect(omarRow.locator(".rec__fit")).toContainText("100%");
  await expect(omarRow.locator(".rec__fit small")).toHaveText("ready-now fit");
  await expect(omarRow.locator(".rec__rationale")).toHaveText(
    "covers the Payments Platform gap at 3.0; 40% available",
  );

  const rohanRow = rows.nth(4);
  await expect(rohanRow).toHaveClass(/rec--mentor/);
  await expect(rohanRow.locator(".rec__rank")).toHaveText("5");
  await expect(rohanRow.locator(".rec__name")).toContainText("Rohan Sharma");
  await expect(rohanRow.locator(".rec__fit")).toContainText("growth");
  await expect(rohanRow.locator(".rec__fit small")).toHaveText("mentorship");
  await expect(rohanRow.locator("span.tag-mentor")).toHaveText(
    "pair with Priya Sharma",
  );
  await expect(rohanRow.locator(".rec__rationale")).toHaveText(
    "growth: learns Payment Gateways under Priya Sharma; 50% available",
  );

  const dmitriRow = rows.nth(5);
  await expect(dmitriRow).toHaveClass(/rec--mentor/);
  await expect(dmitriRow.locator(".rec__rank")).toHaveText("6");
  await expect(dmitriRow.locator(".rec__name")).toContainText("Dmitri Volkov");
});

test("a recommendation row's Assign pre-fills the assign-to-project modal and cancels without writing (#40)", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await openLedgerMigration(page);
  await openCoverageTab(page);

  const rows = recommendationRows(page);
  const omarRow = rows.nth(0);
  await omarRow.getByRole("button", { name: "Assign", exact: true }).click();

  const modal = opModal(page);
  await expect(modal.getByText("Assign to project")).toBeVisible();
  await expect(
    modal.getByLabel("Engineer").locator("option:checked"),
  ).toHaveText("Omar Haddad");
  await expect(modal.getByLabel("Fraction")).toHaveValue("0.4");
  await expect(modal.getByLabel("Valid from")).toHaveValue("2026-06-15");
  await expect(
    modal.getByLabel("Project").locator("option:checked"),
  ).toHaveText("Ledger Migration");

  await modal.getByRole("button", { name: "Cancel" }).click();
  await expect(opModal(page)).toHaveCount(0);

  await expect(omarRow.locator(".rec__rank")).toHaveText("1");
  await expect(omarRow.locator(".rec__name")).toContainText("Omar Haddad");
});

test("scrubbing the as-of rail refetches recommendations as allocations free up (#40)", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await openLedgerMigration(page);
  await openCoverageTab(page);

  const rows = recommendationRows(page);
  const omarRow = rows.nth(0);
  await expect(omarRow.locator(".rec__rationale")).toHaveText(
    "covers the Payments Platform gap at 3.0; 40% available",
  );

  await scrubTo(page, "2026-12-15");

  await expect(omarRow.locator(".rec__rationale")).toHaveText(
    "covers the Payments Platform gap at 3.0; 100% available",
  );
  const rohanRow = rows.nth(4);
  await expect(rohanRow.locator(".rec__rationale")).toHaveText(
    "growth: learns Payment Gateways under Priya Sharma; 100% available",
  );
});
