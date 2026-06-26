const { test, expect } = require("@playwright/test");
const {
  signIn,
  signInAs,
  navigateTo,
  scrubTo,
  rosterRow,
  clickContent,
  railReadout,
  confirmOp,
} = require("./helpers");

// Behaviour-driven coverage of the NEW application SHELL (PRD-frontend success
// criteria): the login gate, sidebar navigation with the global as-of preserved, a
// cold deep link landing on a detail, and a contextual write surfacing in the
// Activity journal. Asserts only what the user sees — gate buttons, page headings,
// the rail's date readout, detail content, and journal entries — never CSS
// classes, ids, or DOM structure.

test("signing in as a person lands on the Board", async ({ page }) => {
  // Nothing is usable until you sign in on the gate's credentials form. Signing in
  // as a seeded person reveals the shell on the Board ("Who's doing what"), at the
  // seed "now".
  await page.goto("/");
  await expect(page.getByLabel("Email")).toBeVisible();
  await expect(page.getByLabel("Password")).toBeVisible();

  await signIn(page, "Aisha Okafor");

  await expect(page.getByText(railReadout("2026-06-15"), { exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Board" })).toBeVisible();
  // The gate is gone — the engineer identity is now the signed-in user.
  await expect(page.getByRole("heading", { name: "Sign in" })).toHaveCount(0);
});

test("the global as-of is preserved as you navigate Board → People → Finance", async ({
  page,
}) => {
  // The as-of is one application-wide value owned by the rail. Scrub it forward,
  // then move through the sidebar: each destination resolves as of the SAME date,
  // shown unchanged on the rail's readout — the as-of survives navigation.
  await signInAs(page, "Admin");
  await scrubTo(page, "2026-07-15");
  await expect(page).toHaveURL(/[?&]date=2026-07-15(\b|$)/);

  await navigateTo(page, "People");
  await expect(page.getByRole("heading", { name: "People" })).toBeVisible();
  await expect(page.getByText(railReadout("2026-07-15"), { exact: true })).toBeVisible();

  await navigateTo(page, "Finance");
  await expect(page.getByRole("heading", { name: "Finance" })).toBeVisible();
  await expect(page.getByText(railReadout("2026-07-15"), { exact: true })).toBeVisible();

  await navigateTo(page, "Board");
  await expect(page.getByRole("heading", { name: "Board" })).toBeVisible();
  await expect(page.getByText(railReadout("2026-07-15"), { exact: true })).toBeVisible();
});

test("a cold deep link opens the engineer detail, not the roster", async ({
  page,
}) => {
  // Deep-linking straight to /people/:id resolves the engineer's DETAIL on a cold
  // load: the Wisp server's history fallback serves the SPA shell for the deep-
  // link path (router.gleam), and the page's init reads the route to open the
  // detail. We sign in (identity is client state) and see Marcus's detail — his
  // timesheet, allocations, the back link — and NOT the roster list.
  await page.goto("/people/2?date=2026-06-15");

  await signIn(page, "Admin");
  await expect(page.getByText(railReadout("2026-06-15"), { exact: true })).toBeVisible();

  await expect(page.getByRole("heading", { name: /Marcus Chen/ })).toBeVisible();
  await expect(page.getByText("Allocations")).toBeVisible();
  await expect(page.getByText("All engineers")).toBeVisible();
  // It is the detail, not the roster list.
  await expect(page.getByRole("heading", { name: "People" })).toHaveCount(0);
  await expect(page).toHaveURL(/\/people\/2\b/);
});

test("a contextual write appears in the Activity log", async ({ page }) => {
  // A contextual operation (Promote on a People detail) is journalled append-only.
  // After applying it, switch to Activity, show "All time" (a fresh write is
  // recorded on system time, today, outside the default recent window), and the
  // operation's summary is listed. Matched by a distinctive substring (≥1) so
  // repeated runs — which append another identical entry — stay green. Promoting
  // Priya to L6 from a fixed past date is idempotent, so re-runs do not conflict.
  await signInAs(page, "Admin");
  await navigateTo(page, "People");
  await expect(page.getByRole("heading", { name: "People" })).toBeVisible();
  await clickContent(rosterRow(page, "Priya Sharma"));
  await expect(page.getByRole("heading", { name: /Priya Sharma/ })).toBeVisible();

  await page.getByRole("button", { name: "Promote" }).dispatchEvent("click");
  await expect(page.getByLabel("New level")).toBeVisible();
  await page.getByLabel("New level").fill("6");
  await page.getByLabel("Effective").fill("2026-06-01");
  await confirmOp(page, "Promote");
  await expect(page.getByText("L6 · Distinguished").first()).toBeVisible();

  await navigateTo(page, "Activity");
  await expect(page.getByRole("heading", { name: "Activity" })).toBeVisible();
  await page.getByLabel("Quick range").selectOption({ label: "All time" });
  await expect(
    page.getByText("Promote engineer 1 to L6 from 2026-06-01").first(),
  ).toBeVisible();
});

// Regression: scrubbing the as-of used to SNAP BACK because RouteChanged
// reconciled the date from the page-load URL (modem.initial_uri) on the self-
// `replace` that follows every scrub — so the rail readout reverted and a second
// API request fired. Here we change the date via the rail's own control on each
// page and assert the readout shows the new date AND STAYS there (no revert), with
// the URL carrying it. (scrubTo could not catch this — it asserts a freshly
// fetched body, never the rail readout persisting.)
for (const path of ["/board", "/people", "/finance"]) {
  test(`the as-of set on the rail sticks (no snap-back) on ${path}`, async ({ page }) => {
    await page.goto(`${path}?date=2026-06-15`);
    await signIn(page, "Admin");
    await expect(
      page.getByText(railReadout("2026-06-15"), { exact: true }),
    ).toBeVisible();

    const picker = page.locator('input[type="date"]');
    await picker.fill("2026-03-10");
    await picker.dispatchEvent("change");

    // the readout reflects the new date immediately...
    await expect(
      page.getByText(railReadout("2026-03-10"), { exact: true }),
    ).toBeVisible();
    // ...and is STILL there after the self-replace settles (the old bug reverted
    // it to the page-load 15 Jun 2026 right about here)...
    await page.waitForTimeout(500);
    await expect(
      page.getByText(railReadout("2026-03-10"), { exact: true }),
    ).toBeVisible();
    await expect(page.getByText(railReadout("2026-06-15"), { exact: true })).toHaveCount(0);
    // ...and the URL carries it.
    await expect(page).toHaveURL(/date=2026-03-10/);
  });
}
