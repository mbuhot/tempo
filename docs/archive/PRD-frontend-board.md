# Tempo — Frontend: Board (Product Requirements)

The landing page after sign-in: the whole consultancy as it stands on the global as-of date. A page PRD
under `PRD-frontend.md` (the umbrella); read the cross-cutting requirements (shell, global as-of,
routing, themed CSS) there.

> Source: `GET /api/board?as_of=` → `BoardSnapshot(date, rows: List(BoardRow), balances:
> List(LeaveBalance))` (shared/types). No new endpoint required.

---

## 1. Purpose

Answer "who is doing what, right now — or on any date" at a glance, and make scrubbing the time rail
visibly change the answer. This is the page that sells the bitemporal idea, so it leads with headline
numbers and re-renders entirely as the date moves.

## 2. Functional requirements

- **FR-BD1 — Headline stats (as-of).** Four figures for the date: **employed** headcount, **utilization**
  (Σ billable allocation fraction ÷ headcount), **on-leave** count, and **billable run-rate** (Σ
  fraction × day rate, per day). All recompute as the as-of date changes.
- **FR-BD2 — On projects, grouped.** Engineers currently `OnProject` grouped by project, each group
  showing the project swatch, title, client, the group's day run-rate and team size; each engineer card
  shows avatar, name, allocation fraction, level, and resolved day rate. One engineer appears under each
  project they are allocated to (mirrors `BoardRow`, one row per project).
- **FR-BD3 — On leave.** Engineers covered by a leave fact on the date, shown as a distinct group with
  the leave kind and end date. Leave takes precedence over allocation in the read model (PRD FR-4): an
  on-leave engineer appears only here, not under a project.
- **FR-BD4 — Unassigned.** Employed engineers with no allocation and no leave on the date, shown as a
  distinct, de-emphasised group.
- **FR-BD5 — Drill-in.** Clicking any engineer navigates to their People detail (`/people/:id`),
  preserving the as-of date.
- **FR-BD6 — Contextual action.** An "Assign" action composes an `AssignToProject` command
  (umbrella FR-U5).
- **FR-BD7 — Empty & boundary states.** A date before anyone is employed, or with no allocations,
  renders explicit empty states per group rather than blank panels.

## 3. Notes

`BoardSnapshot.balances` already carries each employed engineer's annual/sick balance as of the date;
the board may surface a compact balance readout, but the authoritative balance view is the People
detail page. Utilization here is the board's simple billable-fraction-over-headcount measure; the P&L
page carries the per-employee utilization figure (`PnlRow.utilization_pct`).

## 4. Acceptance

- Scrubbing from a date where an engineer is `OnProject` into a covering leave window moves that
  engineer from the project group to the on-leave group, and the stats update, with no reload.
- Scrubbing before the seed range start empties the board to its employed/unassigned states correctly.
