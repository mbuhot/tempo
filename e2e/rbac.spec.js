const { test, expect } = require("@playwright/test");
const { signInAs, navigateTo } = require("./helpers");

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
  // The users list carries the seeded accounts.
  await expect(page.getByText("finance@alembic.com.au")).toBeVisible();
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
