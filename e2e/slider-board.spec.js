const { test, expect } = require("@playwright/test");
const {
  signInAs,
  scrubTo,
  navigateTo,
  escapeRegExp,
  railReadout,
} = require("./helpers");

// Behaviour-driven coverage of the time rail + Board page on the NEW shell. After
// signing in, the Board ("Who's doing what") shows the whole consultancy as of the
// global rail date. We drive the rail to FIXED absolute seed dates (its slider
// value is a unix-day index, independent of the wall clock) and assert only what
// the user sees — the rail's date readout and each engineer's card — never CSS
// classes, ids, or DOM structure.
//
// The Board groups engineers into per-project blocks plus On-leave and Unassigned
// panels. Each engineer's card carries their name and a sub-line (fraction / level
// band / day rate, or the leave kind, or "available"); the project block header
// carries the project title and client. We match the visible text the user reads.

// The Board card region for one engineer: the card carrying their name. Scoped to a
// row-of-text match so a name appearing elsewhere (the sidebar's signed-in user) is
// not mistaken for a board card.
function engineerSays(name, fragment) {
  return new RegExp(`${escapeRegExp(name)}[\\s\\S]*?${escapeRegExp(fragment)}`);
}

test.beforeEach(async ({ page }) => {
  // Sign in as a person; the app lands on the Board at the seed "now".
  await signInAs(page, "Priya Sharma");
  await expect(
    page.getByRole("heading", { name: "Board" }),
  ).toBeVisible();
  await expect(page.getByText("Data Platform").first()).toBeVisible();
});

test("opens at the seed now with Aisha on leave and the others on their projects", async ({
  page,
}) => {
  // At 2026-06-15 Aisha is on annual leave (shown distinctly on the On-leave panel,
  // "annual … til 22 Jun 2026"), Marcus is full-time on Data Platform, and Priya is
  // half-time on Ledger Migration. The project blocks name their clients.
  await expect(page.getByText(engineerSays("Aisha Okafor", "annual"))).toBeVisible();
  await expect(page.getByText("til 22 Jun 2026")).toBeVisible();
  await expect(page.getByText("Data Platform").first()).toBeVisible();
  await expect(page.getByText("Globex Corporation").first()).toBeVisible();
  await expect(page.getByText("Ledger Migration").first()).toBeVisible();
  await expect(page.getByText("Northwind Trading").first()).toBeVisible();
});

test("scrubbing into the future activates Marcus's promotion and rate step", async ({
  page,
}) => {
  // Before 2026-07-01 Marcus is L4 (Staff) charging $1,000/day; scrub past his
  // future-dated promotion AND the L5 rate-card revision and his card reads L5
  // (Principal) at the new $1,400/day, unaided.
  await scrubTo(page, "2026-06-15");
  await expect(page.getByText(engineerSays("Marcus Chen", "L4"))).toBeVisible();
  await expect(page.getByText(engineerSays("Marcus Chen", "$1,000/d"))).toBeVisible();

  await scrubTo(page, "2026-07-15");
  await expect(page.getByText(engineerSays("Marcus Chen", "L5"))).toBeVisible();
  await expect(page.getByText(engineerSays("Marcus Chen", "$1,400/d"))).toBeVisible();
});

test("scrubbing before her leave shows Aisha on her project, not on leave", async ({
  page,
}) => {
  // At 2026-06-01 — before her 2026-06-08..22 leave — Aisha is shown on Data
  // Platform, and the On-leave panel is gone (its "til 22 Jun 2026" marker absent),
  // so she is not on leave that day.
  await scrubTo(page, "2026-06-01");
  await expect(page.getByText(engineerSays("Aisha Okafor", "L6"))).toBeVisible();
  await expect(page.getByText("til 22 Jun 2026")).toHaveCount(0);
});

test("the board re-renders as the rail moves", async ({ page }) => {
  // The same date axis drives the whole board: Aisha reads differently at two
  // dates, proving the rail drives live data rather than a static page. Her
  // on-leave card (its "til 22 Jun 2026" marker) is absent on 2026-06-01 and
  // present on 2026-06-15.
  await scrubTo(page, "2026-06-01");
  await expect(page.getByText("til 22 Jun 2026")).toHaveCount(0);

  await scrubTo(page, "2026-06-15");
  await expect(page.getByText("til 22 Jun 2026")).toBeVisible();
  await expect(page.getByText(engineerSays("Aisha Okafor", "annual"))).toBeVisible();
});

test("an employed but unallocated engineer is shown as Unassigned", async ({
  page,
}) => {
  // Scrub into 2024 — when Marcus is employed (from 2024-06-01) but not yet on any
  // project — and he appears in the Unassigned (bench) panel as "available", while
  // Priya is already on Ledger Migration.
  await scrubTo(page, "2024-06-01");
  await expect(page.getByText("Unassigned")).toBeVisible();
  await expect(page.getByText(engineerSays("Marcus Chen", "available"))).toBeVisible();
  await expect(page.getByText("Ledger Migration").first()).toBeVisible();
});

test("the selected date lives in the URL and is restored on load", async ({
  page,
}) => {
  // The as-of is mirrored in ?date=, so the view is shareable and survives a
  // reload: scrubbing updates ?date, and reloading the root with ?date opens there.
  await scrubTo(page, "2026-07-15");
  await expect(page).toHaveURL(/[?&]date=2026-07-15(\b|$)/);

  await page.goto("/?date=2025-01-01");
  await page.getByRole("button", { name: "Priya Sharma" }).click();
  await expect(page.getByText("1 Jan 2025")).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Board" }),
  ).toBeVisible();
});

test("dragging the rail does not flood history.replaceState (the URL write is debounced)", async ({
  page,
}) => {
  // A real drag fires an `input` on every thumb step — dozens per second. The URL
  // mirror must be DEBOUNCED, not written per tick: the browser caps
  // history.replaceState at ~100 per 10s and a continuous drag blows past it
  // ("SecurityError: Attempt to use history.replaceState() more than 100 times per
  // 10 seconds"). We count replaceState calls across a 150-step burst and assert
  // only a handful land (the settle), while the readout and URL still arrive at the
  // final date.
  await page.evaluate(() => {
    window.__replaceStateCount = 0;
    const original = window.history.replaceState;
    window.history.replaceState = function (...args) {
      window.__replaceStateCount += 1;
      try {
        return original.apply(window.history, args);
      } catch (error) {
        window.__replaceStateThrew = String(error);
      }
    };
  });

  const slider = page.getByLabel("As-of date");
  await slider.evaluate((el) => {
    const setValue = Object.getOwnPropertyDescriptor(
      window.HTMLInputElement.prototype,
      "value",
    ).set;
    for (let day = 20_500; day <= 20_649; day += 1) {
      setValue.call(el, String(day));
      el.dispatchEvent(new Event("input", { bubbles: true }));
    }
  });

  await expect(page.getByText(railReadout("2026-07-15"), { exact: true })).toBeVisible();
  await expect(page).toHaveURL(/[?&]date=2026-07-15(\b|$)/);

  const replaceStateCount = await page.evaluate(() => window.__replaceStateCount);
  expect(replaceStateCount).toBeLessThanOrEqual(5);
});

test("the on-leave panel appears and disappears as the rail moves", async ({
  page,
}) => {
  // The whole on-leave panel is as-of-driven: at 2026-06-01 no one is on leave (its
  // "til 22 Jun 2026" card is absent), at 2026-06-15 Aisha's card is shown, purely
  // by moving the rail.
  await scrubTo(page, "2026-06-01");
  await expect(page.getByText("til 22 Jun 2026")).toHaveCount(0);

  await scrubTo(page, "2026-06-15");
  await expect(page.getByText("til 22 Jun 2026")).toBeVisible();
});

test("the unstaffed-projects lane lists started projects with no one allocated", async ({
  page,
}) => {
  // Two projects run at the seed now with an active run but no allocation, so the
  // board surfaces BOTH under its own "Unstaffed projects" lane — never in the
  // per-project "On projects" blocks (those need an allocation). Platform Telemetry
  // (started 2026-02-01, never staffed) and Edge Analytics (the prospective project
  // — a forward run carrying capacity requirements but no allocation yet). Each card
  // names the project and its client.
  await scrubTo(page, "2026-06-15");
  await expect(
    page.getByRole("heading", { name: "Unstaffed projects" }),
  ).toBeVisible();
  await expect(page.getByText("Platform Telemetry")).toBeVisible();
  await expect(page.getByText("Platform Telemetry")).toHaveCount(1);
  await expect(page.getByText("Edge Analytics")).toBeVisible();
  await expect(page.getByText("Initech Systems")).toBeVisible();
});

test("an unstaffed project's Assign opens the assign modal pre-filled with that project", async ({
  page,
}) => {
  // The per-card "Assign" (distinct from the page-header "+ Assign") opens the
  // canonical "Assign to a project" modal with that card's project already chosen in
  // the Project select, leaving the engineer/fraction/dates for the user. Two
  // unstaffed cards now share the lane (Platform Telemetry + Edge Analytics), so we
  // scope the click to the card whose text names Platform Telemetry.
  await scrubTo(page, "2026-06-15");
  const card = page
    .locator("div")
    .filter({ hasText: /^Platform TelemetryGlobex CorporationAssign$/ });
  await card.getByRole("button", { name: "Assign", exact: true }).click();
  await expect(page.getByText("Assign to a project")).toBeVisible();
  await expect(page.getByLabel("Project")).toHaveValue(/.+/);
  await expect(
    page.getByLabel("Project").locator("option:checked"),
  ).toHaveText("Platform Telemetry");
});

test("a project dormant before its start is absent from the projects list (#19)", async ({
  page,
}) => {
  // Scrub to 2026-01-15 — before Platform Telemetry's 2026-02-01 start — and open
  // the Projects tab: a not-yet-started project must be ABSENT entirely, never shown
  // as 'ended'. The three earlier-started projects still list.
  await scrubTo(page, "2026-01-15");
  await navigateTo(page, "Projects");
  // Exact match: the page-title heading is "Projects"; the section heading "All
  // projects" also contains "projects", so a loose name matches both.
  await expect(
    page.getByRole("heading", { name: "Projects", exact: true }),
  ).toBeVisible();
  await expect(page.getByText("Data Platform")).toBeVisible();
  await expect(page.getByText("Platform Telemetry")).toHaveCount(0);
});
