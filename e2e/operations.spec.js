const { test, expect } = require("@playwright/test");
const {
  signInAs,
  navigateTo,
  scrubTo,
  rosterRow,
  clickContent,
  opModal,
  confirmOp,
} = require("./helpers");

// Behaviour-driven coverage of CONTEXTUAL operations on the new shell: a write that
// commits (Promote, on a People detail) and two writes the database refuses (a
// containment violation and an over-balance leave request), surfacing the typed
// reason. Each operation posts to /api/operations stamped with the signed-in
// actor; on success the page refetches and the change is journalled in Activity.
// We assert only what the user sees — the detail/board re-rendering and the
// rejection sentence — never CSS classes, ids, or DOM structure.
//
// The event log and facts are APPEND-ONLY and never reset between runs, so the
// committing write is designed to be re-run safe: promoting Priya to L6 from a
// fixed past date is idempotent (FOR PORTION OF re-sets the same level from the
// same date — no overlap, no split), so repeated runs leave her at L6 and append
// another identical journal entry, which we match by substring (≥1), never by
// count.

// Open one engineer's detail from the roster. Signed in as a DIFFERENT person so
// the detail's name heading never collides with the sidebar's signed-in-user name.
async function openDetail(page, name) {
  await navigateTo(page, "People");
  await expect(page.getByRole("heading", { name: "People" })).toBeVisible();
  await clickContent(rosterRow(page, name));
  await expect(page.getByRole("heading", { name: new RegExp(name) })).toBeVisible();
}

test("promoting an engineer re-renders their level and charge rate and is journalled", async ({
  page,
}) => {
  // As Aisha, open Priya's detail and promote her to L6 effective 2026-06-01
  // (before the seed "now", so it is in effect now). Her detail header steps to L6
  // (Distinguished); the Board, refetched for the current date, reads her Ledger
  // engagement at the L6 rate ($1,800/day); and the Activity journal records it.
  await signInAs(page, "Admin");
  await openDetail(page, "Priya Sharma");

  // The Promote form opens in the modal (its New-level / Effective fields appear),
  // we set the new level, and confirm with the op-verb button "Promote" scoped to
  // the dialog (the launcher behind the backdrop shares the verb).
  await page.getByRole("button", { name: "Promote" }).dispatchEvent("click");
  await expect(page.getByLabel("New level")).toBeVisible();
  await page.getByLabel("New level").fill("6");
  await page.getByLabel("Effective").fill("2026-06-01");
  await confirmOp(page, "Promote");

  // The detail re-renders at the new band (shown in the header and the employment
  // panel), and the modal closes on success.
  await expect(page.getByText("L6 · Distinguished").first()).toBeVisible();
  await expect(opModal(page)).toHaveCount(0);

  // The Board, as of the seed now, reads Priya's engagement at the L6 rate (she is
  // on two half-time projects, so her card appears on each — match the first).
  await navigateTo(page, "Board");
  await scrubTo(page, "2026-06-15");
  await expect(
    page.getByText(/Priya Sharma[\s\S]*?\$1,800\/d/).first(),
  ).toBeVisible();

  // The journal lists every event newest-first by default, so the just-recorded
  // promotion is shown; match the human summary as a distinctive substring (≥1)
  // rather than a count or position, so repeated runs (which append another
  // identical entry) still pass.
  await navigateTo(page, "Activity");
  await expect(
    page.getByText("Promote engineer 1 to L6 from 2026-06-01").first(),
  ).toBeVisible();
});

test("a containment violation is refused with the reason and leaves the board unchanged", async ({
  page,
}) => {
  // Aisha (employed only from 2025-01-01) cannot be assigned to a project over a
  // window that begins before her employment — the allocation would dangle outside
  // its containing employment. The assign guard refuses it up front with the typed
  // employment reason; the board is unchanged (read-only refusal, re-run safe).
  await signInAs(page, "Admin");
  await navigateTo(page, "Board");
  await expect(page.getByRole("heading", { name: "Board" })).toBeVisible();

  await page.getByRole("button", { name: "+ Assign" }).dispatchEvent("click");
  await expect(page.getByText("Assign to a project")).toBeVisible();
  await page.getByLabel("Engineer").selectOption({ label: "Aisha Okafor" });
  await page.getByLabel("Project").selectOption({ label: "Ledger Migration" });
  await page.getByLabel("Fraction").fill("0.5");
  await page.getByLabel("Valid from").fill("2024-01-01");
  await page.getByLabel("Valid to").fill("2024-06-01");
  await confirmOp(page, "Assign");

  // The user sees the employment rule that fired — not a crash, not a silent
  // success — and the board still shows Aisha on leave at the seed now (her
  // on-leave card runs "til 22 Jun 2026", a marker unique to the on-leave panel).
  await expect(
    page.getByText(/is not employed for the whole allocation period/),
  ).toBeVisible();
  await expect(page.getByText("til 22 Jun 2026")).toBeVisible();
});

test("a leave request beyond the accrued balance is refused with the reason", async ({
  page,
}) => {
  // Priya has well under four months of annual leave accrued by late 2026. The
  // take_leave guard checks the balance on return; the op form surfaces the typed
  // reason. Read-only refusal, so re-run safe.
  await signInAs(page, "Admin");
  await openDetail(page, "Priya Sharma");

  // Take leave opens in the modal; Kind is now a <select> (defaulting to Annual),
  // From/To are dates, and the confirm verb is "Take leave" scoped to the dialog.
  await page.getByRole("button", { name: "Take leave" }).dispatchEvent("click");
  await expect(page.getByLabel("Kind")).toBeVisible();
  await page.getByLabel("Kind").selectOption({ label: "Annual" });
  await page.getByLabel("From").fill("2026-08-01");
  await page.getByLabel("To").fill("2026-12-01");
  await confirmOp(page, "Take leave");

  await expect(
    page.getByText(/insufficient annual leave balance/),
  ).toBeVisible();
});
