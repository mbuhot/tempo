# Tempo — Frontend: Settings (Product Requirements)

The admin surface for the temporal reference data behind the rest of the app: the rate card, salary
bands, and leave policy. A page PRD under `PRD-frontend.md` (umbrella); read the cross-cutting
requirements there.

> Sources: reads for the current `rate_card`, `salary`, and `leave_policy` rows (a `GET /api/settings`
> or per-table reads — settled in the plan). Writes via `POST /api/operations`.

---

## 1. Purpose

Show, and let an admin revise, the per-level reference data the board (charge rate), payroll (salary),
and leave balances (entitlement) derive from — and make clear these are **temporal**: a revision
applies from an effective date forward via `FOR PORTION OF`, it does not overwrite history.

## 2. Functional requirements

- **FR-ST1 — Rate card & salary bands.** A per-level table of the current day rate and monthly salary,
  with a "Revise" action per level: `ReviseRateCard` (publish a new day rate from an effective date) and
  `SetSalary` (publish a new monthly salary from an effective date) — umbrella FR-U5.
- **FR-ST2 — Surgical rate edit.** A `AdjustRateForPortion` action to bump a level's day rate for a
  bounded window (splitting the rate-card row into before/during/after) — PRD FR-6.
- **FR-ST3 — Leave policy.** Show the per-`(kind, level)` entitlement (`days_per_year`) and accrual
  basis from `leave_policy` (ADR-034). Editing policy at runtime (`SetLeavePolicy`) is **deferred**
  (policies are seeded versioned data — ADR-034); the page presents them read-only until that command
  exists, and notes the deferral rather than offering a dead control.

## 3. Notes

Effective-dated writes here are what make future-dating visible elsewhere: revising the Principal rate
from 2027-01-01 changes the board's charge rate and new invoices only once the as-of date crosses that
day (PRD FR-3), with no change to prior periods.

## 4. Acceptance

- A rate revision with a future effective date leaves the board's charge rate unchanged until the as-of
  date reaches it, then steps up.
- The leave-policy section reflects the seeded per-level entitlement and is explicitly read-only
  pending `SetLeavePolicy`.
