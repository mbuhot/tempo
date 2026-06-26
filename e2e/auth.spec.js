const { test, expect } = require("@playwright/test");
const {
  signInAs,
  railReadout,
  USERNAMES,
  DEV_PASSWORD,
} = require("./helpers");

// Behaviour-driven auth specs: real password login, the separate "remember me"
// opt-in (session vs persistent cookie), and logout clearing the session. They only
// read, so they are safe against the append-only, never-reset demo database.

async function sessionCookie(page) {
  const cookies = await page.context().cookies();
  return cookies.find((cookie) => cookie.name === "tempo_session");
}

async function fillCredentials(page, username, password) {
  await page.goto("/");
  await page.getByLabel("Email").fill(username);
  await page.getByLabel("Password").fill(password);
}

test("a wrong password is rejected with an inline error and never signs in", async ({
  page,
}) => {
  await fillCredentials(page, USERNAMES["Admin"], "not-the-password");
  await page.getByRole("button", { name: "Sign in" }).click();

  await expect(page.getByText("invalid username or password")).toBeVisible();
  await expect(
    page.getByText(railReadout("2026-06-15"), { exact: true }),
  ).toHaveCount(0);
  expect(await sessionCookie(page)).toBeUndefined();
});

test("remember me unchecked issues a session cookie (cleared on browser close)", async ({
  page,
}) => {
  await fillCredentials(page, USERNAMES["Admin"], DEV_PASSWORD);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(
    page.getByText(railReadout("2026-06-15"), { exact: true }),
  ).toBeVisible();

  const session = await sessionCookie(page);
  expect(session).toBeDefined();
  expect(session.expires).toBe(-1);
});

test("remember me checked issues a persistent cookie", async ({ page }) => {
  await fillCredentials(page, USERNAMES["Admin"], DEV_PASSWORD);
  await page.getByLabel("Remember me").check();
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(
    page.getByText(railReadout("2026-06-15"), { exact: true }),
  ).toBeVisible();

  const session = await sessionCookie(page);
  expect(session).toBeDefined();
  expect(session.expires).toBeGreaterThan(0);
});

test("logout returns to the gate and clears the session", async ({ page }) => {
  await signInAs(page, "Admin");

  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(page.getByRole("button", { name: "Sign in" })).toBeVisible();
  await expect
    .poll(async () => (await sessionCookie(page)) === undefined)
    .toBe(true);

  await page.reload();
  await expect(page.getByRole("button", { name: "Sign in" })).toBeVisible();
});
