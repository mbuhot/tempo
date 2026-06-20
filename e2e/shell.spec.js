const { test, expect } = require("@playwright/test");
const {
  signInAs,
  navigateTo,
  scrubTo,
  rosterRow,
  clickContent,
  railReadout,
} = require("./helpers");

// Behaviour-driven coverage of the NEW application SHELL (PRD-frontend success
// criteria): the login gate, sidebar navigation with the global as-of preserved, a
// cold deep link landing on a detail, and a contextual write surfacing in the
// Activity journal. Asserts only what the user sees — gate buttons, page headings,
// the rail's date readout, detail content, and journal entries — never CSS
// classes, ids, or DOM structure.

test("signing in as a person lands on the Board", async ({ page }) => {
  // Nothing is usable until you pick an identity on the gate. Picking a seeded
  // person reveals the shell on the Board ("Who's doing what"), at the seed "now".
  await page.goto("/");
  await expect(page.getByRole("button", { name: "Priya Sharma" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Admin" })).toBeVisible();

  await page.getByRole("button", { name: "Aisha Okafor" }).click();

  await expect(page.getByText(railReadout("2026-06-15"), { exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Who's doing what" })).toBeVisible();
  // The gate is gone — the engineer identity is now the signed-in user.
  await expect(page.getByRole("heading", { name: "Sign in" })).toHaveCount(0);
});

test("the global as-of is preserved as you navigate Board → People → Finance", async ({
  page,
}) => {
  // The as-of is one application-wide value owned by the rail. Scrub it forward,
  // then move through the sidebar: each destination resolves as of the SAME date,
  // shown unchanged on the rail's readout — the as-of survives navigation.
  await signInAs(page, "Priya Sharma");
  await scrubTo(page, "2026-07-15");
  await expect(page).toHaveURL(/[?&]date=2026-07-15(\b|$)/);

  await navigateTo(page, "People");
  await expect(page.getByRole("heading", { name: "Engineers" })).toBeVisible();
  await expect(page.getByText(railReadout("2026-07-15"), { exact: true })).toBeVisible();

  await navigateTo(page, "Finance");
  await expect(page.getByRole("heading", { name: "Money" })).toBeVisible();
  await expect(page.getByText(railReadout("2026-07-15"), { exact: true })).toBeVisible();

  await navigateTo(page, "Board");
  await expect(page.getByRole("heading", { name: "Who's doing what" })).toBeVisible();
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

  await page.getByRole("button", { name: "Priya Sharma" }).click();
  await expect(page.getByText(railReadout("2026-06-15"), { exact: true })).toBeVisible();

  await expect(page.getByRole("heading", { name: /Marcus Chen/ })).toBeVisible();
  await expect(page.getByText("Allocations")).toBeVisible();
  await expect(page.getByText("All engineers")).toBeVisible();
  // It is the detail, not the roster list.
  await expect(page.getByRole("heading", { name: "Engineers" })).toHaveCount(0);
  await expect(page).toHaveURL(/\/people\/2\b/);
});

test("a contextual write appears in the Activity log", async ({ page }) => {
  // A contextual operation (Promote on a People detail) is journalled append-only.
  // After applying it, switch to Activity, show "All time" (a fresh write is
  // recorded on system time, today, outside the default recent window), and the
  // operation's summary is listed. Matched by a distinctive substring (≥1) so
  // repeated runs — which append another identical entry — stay green. Promoting
  // Priya to L6 from a fixed past date is idempotent, so re-runs do not conflict.
  await signInAs(page, "Aisha Okafor");
  await navigateTo(page, "People");
  await expect(page.getByRole("heading", { name: "Engineers" })).toBeVisible();
  await clickContent(rosterRow(page, "Priya Sharma"));
  await expect(page.getByRole("heading", { name: /Priya Sharma/ })).toBeVisible();

  await page.getByRole("button", { name: "Promote" }).dispatchEvent("click");
  await expect(page.getByRole("heading", { name: "Promote" })).toBeVisible();
  await page.getByLabel("New level").fill("6");
  await page.getByLabel("Effective").fill("2026-06-01");
  await page.getByRole("button", { name: "Apply" }).dispatchEvent("click");
  await expect(page.getByText("L6 · Distinguished").first()).toBeVisible();

  await navigateTo(page, "Activity");
  await expect(page.getByRole("heading", { name: "Activity log" })).toBeVisible();
  await page.getByLabel("Quick range").selectOption({ label: "All time" });
  await expect(
    page.getByText("Promote engineer 1 to L6 from 2026-06-01").first(),
  ).toBeVisible();
});
