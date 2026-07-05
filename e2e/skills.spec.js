const { test, expect } = require("@playwright/test");
const {
  signInAs,
  navigateTo,
  rosterRow,
  clickContent,
  opModal,
  confirmOp,
} = require("./helpers");

// Behaviour-driven coverage of the capability & skill taxonomy: the People-detail
// Skills tab (an engineer's skill matrix + weighted capability rollup), the
// Assess-skill write, and the Skills taxonomy admin page (capability/skill
// catalogs + the composition matrix, with an inline weight edit). We assert only
// what the user sees — badges, rollup figures, list rows, journal text — never
// CSS classes, ids, or DOM structure.
//
// The event log and facts are APPEND-ONLY and never reset between runs, so every
// write here is re-run safe: the assessment write re-states the SAME skill to
// the SAME level from the SAME fixed past date every run (idempotent, mirroring
// the promote test in operations.spec.js), and the inline weight edit rolls the
// weight back to its seeded value before the test ends. The first test asserts
// only skills/rollups the assessment write never touches, so it stays correct
// across repeated runs.

async function openDetail(page, name) {
  await navigateTo(page, "People");
  await expect(page.getByRole("heading", { name: "People" })).toBeVisible();
  await clickContent(rosterRow(page, name));
  await expect(page.getByRole("heading", { name: new RegExp(name) })).toBeVisible();
}

async function openSkillsTab(page) {
  await page.getByRole("button", { name: "Skills", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Skill matrix" })).toBeVisible();
}

test("the Skills tab renders the seeded skill matrix and capability rollup", async ({
  page,
}) => {
  // As Admin, open Priya's (engineer 1) detail. Her seeded assessments give her
  // L4 on Payment Gateways and L2 on Frontend Development, with Kubernetes never
  // assessed (level 0) — the matrix covers every skill in the taxonomy.
  await signInAs(page, "Admin");
  await openDetail(page, "Priya Sharma");
  await openSkillsTab(page);

  const paymentGateways = page.getByRole("listitem", {
    name: "Payment Gateways",
  });
  await expect(paymentGateways.getByText("L4", { exact: true })).toBeVisible();

  const frontendDevelopment = page.getByRole("listitem", {
    name: "Frontend Development",
  });
  await expect(
    frontendDevelopment.getByText("L2", { exact: true }),
  ).toBeVisible();

  const kubernetes = page.getByRole("listitem", { name: "Kubernetes" });
  await expect(kubernetes.getByText("0", { exact: true })).toBeVisible();

  // The weighted-average rollups, computed from the seeded composition weights
  // and Priya's seeded levels: Payments Platform (32/9), Frontend Delivery
  // (9/6), Platform Infrastructure (0/9, none of its skills assessed).
  await expect(page.getByRole("heading", { name: "Capability rollup" })).toBeVisible();
  const paymentsPlatform = page.getByRole("listitem", {
    name: "Payments Platform",
  });
  await expect(paymentsPlatform.getByText("3.6", { exact: true })).toBeVisible();

  const frontendDelivery = page.getByRole("listitem", {
    name: "Frontend Delivery",
  });
  await expect(frontendDelivery.getByText("1.5", { exact: true })).toBeVisible();

  const platformInfrastructure = page.getByRole("listitem", {
    name: "Platform Infrastructure",
  });
  await expect(
    platformInfrastructure.getByText("0.0", { exact: true }),
  ).toBeVisible();
});

test("recording a skill assessment updates the matrix and rollup and is journalled", async ({
  page,
}) => {
  // Re-assess Priya (engineer 1) on SQL & Database Design (skill 5) to level 3
  // from a fixed past date (2026-06-01, before the seed "now"), so the change is
  // in effect at the seed as-of without scrubbing the rail. Re-running the test
  // re-states the same level from the same date, so the write is idempotent.
  await signInAs(page, "Admin");
  await openDetail(page, "Priya Sharma");
  await openSkillsTab(page);

  await page.getByRole("button", { name: "Assess skill" }).dispatchEvent("click");
  const assessModal = opModal(page);
  await expect(assessModal.getByLabel("Skill")).toBeVisible();
  await assessModal
    .getByLabel("Skill")
    .selectOption({ label: "SQL & Database Design" });
  await assessModal.getByLabel("Experience level").selectOption("3");
  await assessModal.getByLabel("Assessed from").fill("2026-06-01");
  await confirmOp(page, "Record assessment");

  await expect(opModal(page)).toHaveCount(0);
  const sqlDatabaseDesign = page.getByRole("listitem", {
    name: "SQL & Database Design",
  });
  await expect(sqlDatabaseDesign.getByText("L3", { exact: true })).toBeVisible();

  // Data Engineering (SQL & Database Design weight 3 of weight-sum 8, the other
  // two constituent skills unassessed): (3*3)/8 = 1.1.
  const dataEngineering = page.getByRole("listitem", {
    name: "Data Engineering",
  });
  await expect(dataEngineering.getByText("1.1", { exact: true })).toBeVisible();

  await navigateTo(page, "Activity");
  await expect(
    page.getByText("Assess engineer 1 on skill 5 at level 3 from 2026-06-01").first(),
  ).toBeVisible();
});

test("the Skills admin page lists the seeded capabilities, skills, and composition matrix", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Skills");

  await expect(
    page.getByRole("heading", { name: "Capabilities & skills" }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Capabilities", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Skills", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Composition", exact: true }),
  ).toBeVisible();

  // Payments Platform is composed of 4 skills (Payment Gateways, PCI Compliance,
  // Ledger Accounting Systems, API Design).
  const paymentsPlatformRow = page.getByRole("listitem", {
    name: "Payments Platform",
  });
  await expect(paymentsPlatformRow).toContainText("4 skills");

  // API Design feeds both Payments Platform and Frontend Delivery.
  const apiDesignRow = page.getByRole("listitem", { name: "API Design" });
  await expect(apiDesignRow).toContainText("in 2 caps");

  // The composition matrix has a column per capability and a row per skill.
  await expect(
    page.getByRole("columnheader", { name: "Data Engineering", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("columnheader", { name: "Platform Infrastructure", exact: true }),
  ).toBeVisible();
  const paymentGatewaysRow = page.getByRole("row", { name: /Payment Gateways/ });
  await expect(paymentGatewaysRow.getByRole("spinbutton")).toHaveValue("3");
});

test("editing a composition weight inline updates the matrix and rolls back", async ({
  page,
}) => {
  // Payment Gateways feeds only Payments Platform, seeded at weight 3 — the one
  // number input in its matrix row. Re-weight it to 2, confirm the write
  // persists past a reload, then restore 3 so the taxonomy is unchanged for
  // later runs.
  await signInAs(page, "Admin");
  await navigateTo(page, "Skills");

  const paymentGatewaysRow = page.getByRole("row", { name: /Payment Gateways/ });
  const weight = paymentGatewaysRow.getByRole("spinbutton");
  await expect(weight).toHaveValue("3");

  await weight.focus();
  await weight.fill("2");
  await weight.blur();
  await expect(weight).toHaveValue("2");

  await page.reload();
  const weightAfterReload = page
    .getByRole("row", { name: /Payment Gateways/ })
    .getByRole("spinbutton");
  await expect(weightAfterReload).toHaveValue("2");

  await weightAfterReload.focus();
  await weightAfterReload.fill("3");
  await weightAfterReload.blur();
  await expect(weightAfterReload).toHaveValue("3");

  await page.reload();
  await expect(
    page.getByRole("row", { name: /Payment Gateways/ }).getByRole("spinbutton"),
  ).toHaveValue("3");
});
