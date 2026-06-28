const { test, expect } = require("@playwright/test");
const { signInAs, navigateTo } = require("./helpers");

test("an admin creates a project via the wizard", async ({ page }) => {
  const name = `E2E Project ${Date.now()}`;

  await signInAs(page, "Admin");
  await navigateTo(page, "Projects");

  await page.getByRole("button", { name: "+ New project" }).click();

  // Client step
  await page.getByRole("heading", { name: "Client" }).waitFor();
  await page.getByRole("combobox", { name: "Client" }).selectOption({ label: "Globex Corporation" });
  await page.getByRole("button", { name: /Continue/ }).click();

  // Description step
  await page.getByRole("heading", { name: "Description" }).waitFor();
  await page.getByLabel("Project title").fill(name);
  await page.getByLabel("Summary").fill("An e2e test project");
  await page.getByRole("button", { name: /Continue/ }).click();

  // Timeframe & budget step
  await page.getByRole("heading", { name: "Timeframe & budget" }).waitFor();
  await page.getByLabel("Start date").fill("2026-08-01");
  await page.getByLabel("End date").fill("2026-12-01");
  await page.getByLabel("Budget").fill("50000");
  await page.getByLabel("Target completion").fill("2026-11-15");
  await page.getByRole("button", { name: /Continue/ }).click();

  // Team requirements step
  await page.getByRole("heading", { name: "Team requirements" }).waitFor();
  await page.getByRole("button", { name: "+ Add requirement" }).click();
  await page.getByRole("combobox", { name: "Level" }).nth(0).selectOption("4");
  await page.getByRole("spinbutton", { name: "Quantity" }).nth(0).fill("2");
  await page.getByRole("button", { name: "+ Add requirement" }).click();
  await page.getByRole("combobox", { name: "Level" }).nth(1).selectOption("5");
  await page.getByRole("spinbutton", { name: "Quantity" }).nth(1).fill("1");
  await page.getByRole("button", { name: /Continue/ }).click();

  // Contract step
  await page.getByRole("heading", { name: "Contract", exact: true }).waitFor();
  await page.getByLabel("Contract start").fill("2026-08-01");
  await page.getByLabel("Contract end").fill("2026-12-01");
  await page.getByRole("button", { name: /Continue/ }).click();

  // Confirmation step
  await page.getByRole("heading", { name: "Confirmation" }).waitFor();
  await page.getByLabel("Confirmed for creation").check();

  const [commit] = await Promise.all([
    page.waitForResponse((r) => r.url().includes("/api/operations")),
    page.getByRole("button", { name: "Finish" }).click(),
  ]);
  expect(commit.status()).toBe(200);

  // The journal records the project creation.
  await navigateTo(page, "Activity");
  await expect(
    page.getByText(new RegExp(`Create project ${name}`)).first(),
  ).toBeVisible();
});
