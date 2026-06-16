const { test, expect } = require("@playwright/test");

// Behaviour-driven coverage of the time slider + org board. Drives the real app
// (Wisp serving the Lustre SPA) against a seeded PG19, asserting only what the
// user sees: the date shown and the sentence per engineer — never CSS classes,
// ids, or DOM structure — so the suite is robust to markup changes.
//
// Determinism: the slider value is a unix-day index, so we drive it to FIXED
// absolute seed dates rather than the wall clock.
//
//   2024-01-01 = day 19723 (slider min)   2026-06-15 = day 20619 (seed "now")
//   2024-06-01 = day 19875                 2026-07-15 = day 20649
//   2026-06-01 = day 20605                 2026-12-31 = day 20818 (slider max)
const DAY = {
  "2024-06-01": "19875",
  "2026-06-01": "20605",
  "2026-06-15": "20619",
  "2026-07-15": "20649",
};

// Move the slider to a fixed seed day index and wait for the board to re-render
// for that date (the "As of YYYY-MM-DD" heading is the visible confirmation).
async function scrubTo(page, isoDate) {
  const slider = page.getByLabel("Board date");
  await slider.fill(DAY[isoDate]);
  await expect(
    page.getByRole("heading", { name: `As of ${isoDate}` }),
  ).toBeVisible();
}

// Build a regex matching the single visible line the board shows for one
// engineer: their name, then (anywhere after it on the same line) the expected
// fragment of their situation — e.g. "On leave: annual" or "Data Platform". This
// asserts only what the user reads, with no reference to the tag, class, or id of
// the element that carries it, so the suite survives any DOM restructure.
function engineerSays(name, fragment) {
  const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`${escape(name)}.*${escape(fragment)}`);
}

// The board line for one engineer carries the expected fragment (e.g. their
// project or "On leave: annual").
function expectEngineerLine(page, name, fragment) {
  return expect(page.getByText(engineerSays(name, fragment))).toBeVisible();
}

// No board line shows this engineer with the given fragment (e.g. Aisha is not
// "On leave" on a date before her leave begins).
function expectNoEngineerLine(page, name, fragment) {
  return expect(page.getByText(engineerSays(name, fragment))).toHaveCount(0);
}

test.beforeEach(async ({ page }) => {
  await page.goto("/");
  // The app boots at the seed "now" and shows the board for it.
  await expect(
    page.getByRole("heading", { name: "As of 2026-06-15" }),
  ).toBeVisible();
});

test("opens at the seed now with Aisha on leave", async ({ page }) => {
  // The board for 2026-06-15. Aisha's allocation is suppressed by her covering
  // leave fact and shown distinctly; Marcus is on his project. Engineers,
  // projects, and clients are all visible for the date.
  await expectEngineerLine(page, "Aisha Okafor", "On leave: annual");
  await expectEngineerLine(page, "Marcus Chen", "Data Platform for Globex Corporation");
  await expectEngineerLine(page, "Priya Sharma", "Ledger Migration for Northwind Trading");
});

test("scrubbing into the future activates Marcus's promotion", async ({ page }) => {
  // Before 2026-07-01 Marcus is L4 charging $1,000/day; scrub past his
  // future-dated promotion and his level AND charge rate step up unaided.
  await scrubTo(page, "2026-06-15");
  await expectEngineerLine(page, "Marcus Chen", "L4");
  await expectEngineerLine(page, "Marcus Chen", "$1000/day");

  await scrubTo(page, "2026-07-15");
  await expectEngineerLine(page, "Marcus Chen", "L5");
  await expectEngineerLine(page, "Marcus Chen", "$1400/day");
});

test("scrubbing before her leave shows Aisha allocated, not on leave", async ({
  page,
}) => {
  // At 2026-06-01 — before her 2026-06-08..06-22 leave — Aisha is shown on her
  // project, not "On leave".
  await scrubTo(page, "2026-06-01");
  await expectEngineerLine(page, "Aisha Okafor", "Data Platform for Globex Corporation");
  await expectNoEngineerLine(page, "Aisha Okafor", "On leave");
});

test("the board changes as the slider moves", async ({ page }) => {
  // The whole-board re-render: the same engineer reads differently at two dates,
  // proving the slider drives real board data rather than a static page.
  await scrubTo(page, "2026-06-01");
  await expectEngineerLine(page, "Aisha Okafor", "Data Platform");

  await scrubTo(page, "2026-06-15");
  await expectEngineerLine(page, "Aisha Okafor", "On leave: annual");
});

test("an employed but unallocated engineer is shown as Unassigned", async ({
  page,
}) => {
  // Regression: scrubbing into 2024 — when Marcus is employed but not yet on any
  // project and not on leave — must show him as "Unassigned". This case
  // previously made GET /api/board return 500 (the board's only NULL-allocation
  // path). Priya is already on Ledger Migration then.
  await scrubTo(page, "2024-06-01");
  await expectEngineerLine(page, "Marcus Chen", "Unassigned");
  await expectEngineerLine(page, "Priya Sharma", "Ledger Migration for Northwind Trading");
  await expectNoEngineerLine(page, "Marcus Chen", "Data Platform");
});

test("the selected date is in the URL and is restored on load", async ({
  page,
}) => {
  // The date lives in the query string, so the view is shareable and survives a
  // reload: scrubbing updates ?date, and loading a URL with ?date opens there.
  await scrubTo(page, "2026-07-15");
  await expect(page).toHaveURL(/[?&]date=2026-07-15(\b|$)/);

  await page.goto("/?date=2025-03-01");
  await expect(
    page.getByRole("heading", { name: "As of 2025-03-01" }),
  ).toBeVisible();
  await expectEngineerLine(page, "Marcus Chen", "Data Platform for Globex Corporation");
});
