const { expect } = require("@playwright/test");

// Shared helpers for the Tempo e2e suite against the NEW frontend shell: a login
// gate, a left sidebar, and one global as-of time rail. Everything here asserts
// only what the user sees — visible text, ARIA labels, roles — never CSS classes,
// ids, or DOM structure.

// --- The as-of time rail -----------------------------------------------------
// The rail owns one global as-of date, mirrored in the URL as ?date=YYYY-MM-DD.
// Its slider value is a unix-day index, so we drive it to FIXED absolute seed
// dates rather than the wall clock; the rail's date readout ("15 Jun 2026") is
// the visible confirmation a scrub landed. (client/time.gleam: slider aria-label
// "As-of date"; readout formatted "<d> <Mon> <YYYY>".)
//
//   2024-01-01 = day 19723 (slider min)   2026-06-15 = day 20619 (seed "now")
//   2024-06-01 = day 19875                 2026-07-01 = day 20635
//   2025-01-01 = day 20089                 2026-07-15 = day 20649
//   2025-05-26 = day 20234                 2026-12-31 = day 20818 (slider max)
//   2026-04-15 = day 20558                 2026-06-01 = day 20605
const DAY_INDEX = {
  "2024-06-01": "19875",
  "2025-01-01": "20089",
  "2026-01-15": "20468",
  "2025-05-26": "20234",
  "2026-01-01": "20454",
  "2026-04-15": "20558",
  "2026-06-01": "20605",
  "2026-06-08": "20612",
  "2026-06-09": "20613",
  "2026-06-10": "20614",
  "2026-06-15": "20619",
  "2026-07-15": "20649",
  "2026-08-15": "20680",
  "2026-09-15": "20711",
  "2026-10-15": "20741",
  "2026-12-15": "20802",
};

// The rail's date readout for an ISO date, e.g. "2026-06-15" -> "15 Jun 2026".
const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];
function railReadout(isoDate) {
  const [year, month, day] = isoDate.split("-");
  return `${Number(day)} ${MONTHS[Number(month) - 1]} ${year}`;
}

// Move the rail to a fixed seed date and wait for the readout to confirm it.
// The rail renders a custom track over a zero-width <input type="range">, so the
// native control is not "visible" to a pointer; scrubbing it from script means
// setting its value and firing the same input/change events a drag would, which
// the rail debounces into one as-of change. The readout ("<d> <Mon> <YYYY>") is
// the visible confirmation the new date took.
async function scrubTo(page, isoDate) {
  const index = DAY_INDEX[isoDate];
  if (!index) throw new Error(`No day index registered for ${isoDate}`);
  const slider = page.getByLabel("As-of date");
  await slider.evaluate((el, value) => {
    const setValue = Object.getOwnPropertyDescriptor(
      window.HTMLInputElement.prototype,
      "value",
    ).set;
    setValue.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }, index);
  // The rail's readout element holds exactly the readout string; some pages embed
  // the same date inside a longer blurb, so match it exactly to resolve only the
  // rail.
  await expect(page.getByText(railReadout(isoDate), { exact: true })).toBeVisible();
}

// --- The login gate ----------------------------------------------------------
// Nothing is usable until you sign in with real credentials. The gate is an
// email/password form with a separate "remember me" opt-in; submitting authenticates
// server-side and reveals the shell, landing on the Board. We wait for the rail's
// seed-now readout as the visible confirmation the app booted. (client/app.gleam:
// view_login.) The dev cast all share one seeded password; their usernames are
// emails (server account/seed.gleam — keep these two in sync with it).
const DEV_PASSWORD = "tempo-dev-password";

const USERNAMES = {
  "Priya Sharma": "priya.sharma@alembic.com.au",
  "Marcus Chen": "marcus.chen@alembic.com.au",
  "Aisha Okafor": "aisha.okafor@alembic.com.au",
  Admin: "admin@alembic.com.au",
  Ops: "ops@alembic.com.au",
};

// Fill and submit the login form for a seeded identity WITHOUT navigating first (so
// a deep-linked URL stays put) and without waiting for any particular page — the
// caller asserts what should appear. The gate is shown whenever signed out, on any
// route, so this works after a deep-link goto.
async function signIn(page, identity) {
  const username = USERNAMES[identity];
  if (!username) throw new Error(`No seeded username for identity ${identity}`);
  await page.getByLabel("Email").fill(username);
  await page.getByLabel("Password").fill(DEV_PASSWORD);
  await page.getByRole("button", { name: "Sign in" }).click();
}

// Sign in as a seeded identity from the root and wait for the shell to boot (the
// rail's seed-now readout) — the common case for specs that just need to be inside
// the app.
async function signInAs(page, identity) {
  await page.goto("/");
  await signIn(page, identity);
  await expect(
    page.getByText(railReadout("2026-06-15"), { exact: true }),
  ).toBeVisible();
}

// --- Sidebar navigation ------------------------------------------------------
// The sidebar links carry a leading icon + a label; matching by the visible label
// resolves the right one. After a click the URL path changes (modem pushes) while
// the ?date= as-of is carried across. (client/app.gleam: view_nav_link.)
async function navigateTo(page, label) {
  await page.getByRole("link", { name: label }).click();
}

// --- Clicking content-area controls ------------------------------------------
// An ordinary user click on a content-area row or panel button. (The shell's grid
// container is a `.app` div inside the index.html `#app` mount, so nothing
// overlaps the content column — a normal click lands.)
async function clickContent(locator) {
  await expect(locator).toBeVisible();
  await locator.click();
}

// The roster row for an engineer, by their visible name.
function rosterRow(page, name) {
  return page.getByRole("row", { name: new RegExp(escapeRegExp(name)) });
}

// --- The contextual-operation modal ------------------------------------------
// Every page now composes its op forms in a centred modal overlaid on a dimmed
// backdrop (ui.modal). The launcher that opened it (e.g. a "Promote" / "Assign"
// button) stays in the page behind the backdrop, so its verb can collide with the
// modal's own confirm verb. Scope confirm clicks and in-form controls through this
// locator so they resolve only the open dialog. The dialog carries no ARIA role,
// so it is reached by its overlay container.
function opModal(page) {
  return page.locator(".modal");
}

// Click the modal's footer confirm button by its op-verb label (e.g. "Promote",
// "Assign", "Draft"), scoped to the open dialog so a same-named launcher behind
// the backdrop never wins the match.
async function confirmOp(page, verb) {
  await opModal(page).getByRole("button", { name: verb, exact: true }).click();
}

// The invoices-table row for an invoice id ("#<id>" shown in its first cell).
function invoiceRowById(page, id) {
  return page.getByRole("row", { name: new RegExp(`#${id}\\b`) });
}

// The set of invoice ids currently shown in the invoices table, read from the
// "#<id>" cells. Used to identify the invoice a Draft just created so write beats
// stay re-run safe against an append-only, never-reset database.
async function visibleInvoiceIds(page) {
  const text = await page.locator("body").innerText();
  const matches = text.match(/#(\d+)/g) || [];
  return new Set(matches.map((m) => Number(m.slice(1))));
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

module.exports = {
  DAY_INDEX,
  DEV_PASSWORD,
  USERNAMES,
  railReadout,
  scrubTo,
  signIn,
  signInAs,
  navigateTo,
  clickContent,
  rosterRow,
  invoiceRowById,
  visibleInvoiceIds,
  escapeRegExp,
  opModal,
  confirmOp,
};
