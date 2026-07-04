const { test, expect } = require("@playwright/test");
const { signInAs, navigateTo, clickContent, rosterRow } = require("./helpers");

// Behaviour-driven coverage of role-based access on the new shell: the sidebar shows
// only the tabs a role's permissions allow, and the Owner-only Access page visualizes
// the role->permission matrix and grants/revokes user roles. Read-only or re-run-safe
// (the grant/revoke test toggles a role on then back off), so safe against the
// append-only demo database.

test("an engineer sees only the operational tabs", async ({ page }) => {
  await signInAs(page, "Priya Sharma");

  await expect(page.getByRole("link", { name: "Board" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Projects" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Clients" })).toBeVisible();

  await expect(page.getByRole("link", { name: "People" })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Finance" })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Activity" })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Access" })).toHaveCount(0);
});

test("finance sees People and Finance, but not Access", async ({ page }) => {
  await signInAs(page, "Finance");

  await expect(page.getByRole("link", { name: "People" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Finance" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Activity" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Access" })).toHaveCount(0);
});

test("only the owner sees the Access tab", async ({ page }) => {
  await signInAs(page, "Admin");
  await expect(page.getByRole("link", { name: "Access" })).toBeVisible();
});

test("an engineer does not see the Skills admin link", async ({ page }) => {
  await signInAs(page, "Priya Sharma");
  await expect(page.getByRole("link", { name: "Skills" })).toHaveCount(0);
});

test("the owner sees the Skills admin link", async ({ page }) => {
  await signInAs(page, "Admin");
  await expect(page.getByRole("link", { name: "Skills" })).toBeVisible();
});

test("the Access page visualizes the role-permission matrix and lists users", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Access");

  await expect(page.getByRole("heading", { name: "Access" })).toBeVisible();
  // The matrix has a column per role and a row per permission key.
  await expect(
    page.getByRole("columnheader", { name: "owner", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("columnheader", { name: "engineer", exact: true }),
  ).toBeVisible();
  await expect(page.getByText("payroll.run", { exact: true })).toBeVisible();
  await expect(page.getByText("roles.manage", { exact: true })).toBeVisible();
  await expect(page.getByText("skills.manage", { exact: true })).toBeVisible();
  // The users list carries the seeded accounts.
  await expect(page.getByText("finance@alembic.com.au")).toBeVisible();
});

// In-page launcher gating: a role that may VIEW a page but not perform a given action
// does not see that action's launcher, while the owner (who may) does. Each gated case
// is paired with an owner case over the same page/button — across separate tests, since
// each runs in its own browser context (a fresh login) — so a broken gate fails either
// the hide or the show, never the mere absence of a non-feature.

test("an engineer viewing the board sees no allocation launchers", async ({
  page,
}) => {
  // Priya (engineer) has read.projects so she lands on the Board, but lacks
  // allocation.manage — so neither the "+ Assign" header launcher nor the per-card
  // "Roll off" launchers are shown.
  await signInAs(page, "Priya Sharma");
  await expect(page.getByRole("heading", { name: "Board" })).toBeVisible();
  await expect(page.getByRole("button", { name: "+ Assign" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Roll off" })).toHaveCount(0);
});

test("the owner viewing the board sees the allocation launchers", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await expect(page.getByRole("heading", { name: "Board" })).toBeVisible();
  await expect(page.getByRole("button", { name: "+ Assign" })).toBeVisible();
  // The board's per-allocation cards each carry a "Roll off" launcher (allocation.manage).
  await expect(
    page.getByRole("button", { name: "Roll off" }).first(),
  ).toBeVisible();
});

test("finance viewing an engineer does not see the Promote launcher", async ({
  page,
}) => {
  // Finance has read.engineers (so it can open the detail) but not engineer.promote.
  await signInAs(page, "Finance");
  await navigateTo(page, "People");
  await clickContent(rosterRow(page, "Marcus Chen"));
  await expect(page.getByText("‹ All engineers")).toBeVisible();
  await expect(page.getByRole("button", { name: "Promote" })).toHaveCount(0);
});

test("the owner viewing an engineer sees the Promote launcher", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "People");
  await clickContent(rosterRow(page, "Marcus Chen"));
  await expect(page.getByRole("button", { name: "Promote" })).toBeVisible();
});

test("finance viewing an engineer does not see the Assess-skill launcher", async ({
  page,
}) => {
  // Finance has read.engineers but not skills.assess.
  await signInAs(page, "Finance");
  await navigateTo(page, "People");
  await clickContent(rosterRow(page, "Marcus Chen"));
  await expect(page.getByRole("button", { name: "Assess skill" })).toHaveCount(0);
});

test("the owner viewing an engineer sees the Assess-skill launcher", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "People");
  await clickContent(rosterRow(page, "Marcus Chen"));
  await expect(page.getByRole("button", { name: "Assess skill" })).toBeVisible();
});

test("finance viewing a project's coverage tab does not see the Set-requirement launcher", async ({
  page,
}) => {
  // Finance has read.projects (so it can open the project detail and its
  // Capability coverage tab) but not project.manage. Scoped to the coverage
  // panel, since the Overview tab's capacity-requirements panel shares the
  // same launcher label and stays in the DOM behind the tab switch.
  await signInAs(page, "Finance");
  await navigateTo(page, "Projects");
  await clickContent(page.getByText("Ledger Migration").first());
  await page.getByRole("button", { name: "Capability coverage" }).click();
  const coveragePanel = page.locator(".panel", { hasText: "Capability coverage" });
  await expect(
    coveragePanel.getByRole("heading", { name: "Capability coverage" }),
  ).toBeVisible();
  await expect(
    coveragePanel.getByRole("button", { name: "Set requirement" }),
  ).toHaveCount(0);
});

test("the owner viewing a project's coverage tab sees the Set-requirement launcher", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Projects");
  await clickContent(page.getByText("Ledger Migration").first());
  await page.getByRole("button", { name: "Capability coverage" }).click();
  const coveragePanel = page.locator(".panel", { hasText: "Capability coverage" });
  await expect(
    coveragePanel.getByRole("button", { name: "Set requirement" }),
  ).toBeVisible();
});

test("a manager viewing settings does not see the Revise-rate launcher", async ({
  page,
}) => {
  // Ops (manager) has read.finances (so Settings opens) but not ratecard.manage.
  await signInAs(page, "Ops");
  await navigateTo(page, "Settings");
  await expect(page.getByRole("heading", { name: "Settings" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Revise rate" })).toHaveCount(0);
});

test("the owner viewing settings sees the Revise-rate launcher", async ({
  page,
}) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Settings");
  await expect(page.getByRole("button", { name: "Revise rate" })).toBeVisible();
});

test("the owner can grant and revoke a user's role", async ({ page }) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Access");

  // Marcus's row carries a toggle per role; grant 'finance' (off -> on), then revoke
  // it (on -> off) so the test is re-run safe against the never-reset database.
  const row = page.locator(".access__user", { hasText: "Marcus Chen" });
  const financeToggle = row.getByRole("button", { name: "finance", exact: true });

  await expect(financeToggle).toHaveAttribute("aria-pressed", "false");
  await financeToggle.click();
  await expect(financeToggle).toHaveAttribute("aria-pressed", "true");
  await financeToggle.click();
  await expect(financeToggle).toHaveAttribute("aria-pressed", "false");
});
