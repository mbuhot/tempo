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

function recommendationRow(page, rank, name) {
  return recommendationsPanel(page).getByRole("listitem", {
    name: `Rank ${rank}: ${name}`,
  });
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

  await expect(panel.getByRole("listitem")).toHaveCount(6);

  const readyNowNames = ["Omar Haddad", "Mei Lin", "Sofia Rossi", "Tunde Okafor"];
  for (const [zeroBasedIndex, name] of readyNowNames.entries()) {
    await expect(recommendationRow(page, zeroBasedIndex + 1, name)).toBeVisible();
  }

  const omarRow = recommendationRow(page, 1, "Omar Haddad");
  await expect(omarRow.getByText("100%")).toBeVisible();
  await expect(omarRow.getByText("ready-now fit")).toBeVisible();
  await expect(
    omarRow.getByText("covers the Payments Platform gap at 3.0; 40% available"),
  ).toBeVisible();

  const rohanRow = recommendationRow(page, 5, "Rohan Sharma");
  await expect(rohanRow.getByText("mentorship")).toBeVisible();
  await expect(rohanRow.getByText("pair with Priya Sharma")).toBeVisible();
  await expect(
    rohanRow.getByText(
      "growth: learns Payment Gateways under Priya Sharma; 50% available",
    ),
  ).toBeVisible();

  await expect(recommendationRow(page, 6, "Dmitri Volkov")).toBeVisible();
});

test("a recommendation row's Assign pre-fills the assign-to-project modal and cancels without writing (#40)", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await openLedgerMigration(page);
  await openCoverageTab(page);

  const omarRow = recommendationRow(page, 1, "Omar Haddad");
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

  await expect(recommendationRow(page, 1, "Omar Haddad")).toBeVisible();
});

test("scrubbing the as-of rail refetches recommendations as allocations free up (#40)", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await openLedgerMigration(page);
  await openCoverageTab(page);

  const omarRow = recommendationRow(page, 1, "Omar Haddad");
  await expect(
    omarRow.getByText("covers the Payments Platform gap at 3.0; 40% available"),
  ).toBeVisible();

  await scrubTo(page, "2026-12-15");

  await expect(
    omarRow.getByText("covers the Payments Platform gap at 3.0; 100% available"),
  ).toBeVisible();
  const rohanRow = recommendationRow(page, 5, "Rohan Sharma");
  await expect(
    rohanRow.getByText(
      "growth: learns Payment Gateways under Priya Sharma; 100% available",
    ),
  ).toBeVisible();
});
