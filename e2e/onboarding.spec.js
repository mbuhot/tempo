const { test, expect } = require("@playwright/test");
const { signIn, signInAs, navigateTo } = require("./helpers");

// Behaviour-driven onboarding spec: a manager fills the wizard and hands off to
// Finance; Finance confirms payroll and commits, creating a real engineer. The
// database is append-only and never reset, so each run mints a fresh engineer —
// the spec follows the specific instance it creates (by its URL id) rather than
// relying on shared queue state.

const NAME = "E2E Onboard Engineer";
const EMAIL = "e2e.onboard@example.com";

// Pull the instance id out of the wizard URL (/onboard/<id>/<step>).
function instanceIdFrom(url) {
  const match = url.match(/\/onboard\/([^/]+)\//);
  if (!match) throw new Error(`no instance id in url ${url}`);
  return match[1];
}

test("a manager onboards an engineer and Finance commits it", async ({ page }) => {
  // --- Manager fills steps 1–5 and hands off ---------------------------------
  await signInAs(page, "Ops");
  await navigateTo(page, "Onboard");
  await page.getByRole("button", { name: "Start onboarding" }).click();

  await expect(page).toHaveURL(/\/onboard\/[^/]+\/identity/);
  const id = instanceIdFrom(page.url());

  // Identity.
  await page.getByLabel("Full name").fill(NAME);
  await page.getByLabel("Work email").fill(EMAIL);
  await page.getByRole("button", { name: /Continue/ }).click();

  // Level — and prove durability: reload mid-flow, step Back, and the saved name
  // is still there (the draft lives in the database, not a socket).
  await page.getByLabel("Level").waitFor();
  await page.reload();
  await page.getByRole("button", { name: /Back/ }).click();
  await expect(page.getByLabel("Full name")).toHaveValue(NAME);
  await page.getByRole("button", { name: /Continue/ }).click();

  await page.getByLabel("Level").waitFor();
  await page.getByLabel("Level").selectOption("5");
  await page.getByRole("button", { name: /Continue/ }).click();

  // Employment.
  await page.getByLabel("Start date").waitFor();
  await page.getByLabel("Start date").fill("2026-07-13");
  await page.getByRole("button", { name: /Continue/ }).click();

  // Contact (optional fields) — straight through.
  await page.getByRole("heading", { name: "Contact" }).waitFor();
  await page.getByRole("button", { name: /Continue/ }).click();

  // Banking, then hand off to Finance.
  await page.getByLabel("Bank").waitFor();
  await page.getByLabel("Bank").fill("ANZ");
  await page.getByLabel("Account number").fill("00112233");
  await page.getByLabel("Account name").fill("E Onboard");
  await page.getByRole("button", { name: /Hand off to Finance/ }).click();

  // After hand-off the manager is returned to the onboarding landing.
  await expect(page).toHaveURL(/\/onboard(\?|$)/);

  // --- Finance picks it up from the queue and commits ------------------------
  await page.context().clearCookies();
  await page.goto(`/onboard/${id}`);
  await signIn(page, "Finance");

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

  // Commit lands the engineer; the journal records the onboarding.
  await navigateTo(page, "Activity");
  await expect(page.getByText(new RegExp(`Onboard ${NAME}`)).first()).toBeVisible();
});
