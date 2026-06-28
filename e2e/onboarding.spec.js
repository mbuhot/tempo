const { test, expect } = require("@playwright/test");
const { signIn, signInAs, navigateTo, rosterRow } = require("./helpers");

// Behaviour-driven onboarding spec: a manager opens the onboarding wizard from the
// People page (a modal), fills it, and hands off to Finance; the draft then appears
// as a row in the People list, which Finance clicks to resume, confirm payroll, and
// commit — creating a real engineer. The database is append-only and never reset, so
// each run uses a unique name to find its own draft row.

test("a manager onboards via the People modal and Finance commits it", async ({
  page,
}) => {
  const name = `E2E Onboard ${Date.now()}`;
  const email = "e2e.onboard@example.com";

  // --- Manager fills the wizard modal and hands off --------------------------
  await signInAs(page, "Ops");
  await navigateTo(page, "People");
  await page.getByRole("button", { name: "+ Onboard" }).click();

  // The wizard opens as a modal at the Identity step.
  await page.getByLabel("Full name").fill(name);
  await page.getByLabel("Work email").fill(email);
  await page.getByRole("button", { name: /Continue/ }).click();

  await page.getByLabel("Level").waitFor();
  await page.getByLabel("Level").selectOption("5");
  await page.getByRole("button", { name: /Continue/ }).click();

  await page.getByLabel("Start date").waitFor();
  await page.getByLabel("Start date").fill("2026-07-13");
  await page.getByRole("button", { name: /Continue/ }).click();

  // Contact (optional fields) — straight through.
  await page.getByRole("heading", { name: "Contact" }).waitFor();
  await page.getByRole("button", { name: /Continue/ }).click();

  await page.getByLabel("Bank").waitFor();
  await page.getByLabel("Bank").fill("ANZ");
  await page.getByLabel("Account number").fill("00112233");
  await page.getByLabel("Account name").fill("E Onboard");
  await page.getByRole("button", { name: /Hand off to Finance/ }).click();

  // The modal closes and the draft shows as a row in the People list.
  await expect(rosterRow(page, name)).toBeVisible();

  // --- Finance resumes from the People list and commits ----------------------
  await page.context().clearCookies();
  await page.reload();
  await signIn(page, "Finance");
  await navigateTo(page, "People");

  await rosterRow(page, name).click();

  const confirm = page.getByLabel("Payroll details entered externally");
  await confirm.waitFor();
  await Promise.all([
    page.waitForResponse(
      (r) => r.url().includes("/field") && r.request().method() === "POST",
    ),
    confirm.check(),
  ]);
  const [commit] = await Promise.all([
    page.waitForResponse((r) => r.url().includes("/api/operations")),
    page.getByRole("button", { name: "Confirm & commit" }).click(),
  ]);
  expect(commit.status()).toBe(200);

  // The journal records the onboarding.
  await navigateTo(page, "Activity");
  await expect(page.getByText(new RegExp(`Onboard ${name}`)).first()).toBeVisible();
});
