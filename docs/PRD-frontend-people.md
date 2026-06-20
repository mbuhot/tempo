# Tempo — Frontend: People (Product Requirements)

The engineer roster and the per-engineer detail record — the richest page, since an engineer is the
anchor that most facts hang off. A page PRD under `PRD-frontend.md` (umbrella); read the cross-cutting
requirements there.

> Sources: `GET /api/people?as_of=` (new — roster list), `GET /api/engineers/:id?as_of=` (new — detail
> bundle), `GET /api/timesheet?engineer_id=&week_of=` (existing — `TimesheetWeek`). Writes via
> `POST /api/operations`. Detail facts read from the existing `engineer_*_current` views.

---

## 1. Purpose

List everyone employed as of the date, and let you open one person to see their full record — contact,
banking, emergency, employment and role history, allocations, leave balance and history, and the
weekly timesheet — and to act on them (promote, leave, roll off, terminate, edit details).

## 2. Functional requirements — roster

- **FR-PE1 — Roster (as-of).** A table of engineers employed on the date: name + email, level (Ln +
  band name), status (on leave / the project(s) they are on / unassigned), total allocated fraction,
  annual-leave balance, and day rate. Rows click through to detail.
- **FR-PE2 — Onboard.** An "Onboard" action composes `OnboardEngineer` (umbrella FR-U5).

## 3. Functional requirements — engineer detail (`/people/:id`)

- **FR-PE3 — Header & summary.** Avatar, name, level/band, and a one-line situation as of the date (on
  leave until …, allocated to …, or unassigned).
- **FR-PE4 — Allocations.** Every allocation on record for the engineer with project, fraction, period,
  and whether it is active or ended **as of the date** (the as-of date marks rows active/ended, it does
  not hide them).
- **FR-PE5 — Timesheet.** The weekly grid for the week containing the as-of date (`TimesheetWeek`):
  one row per project allocated that week, Mon–Sun columns, hours per cell, cells disabled when the day
  is not covered by an allocation or the engineer is on leave. Submitting posts `LogWeek`; a rejected
  write (a day not allocated) shows the typed error inline (PRD FR-5).
- **FR-PE6 — Leave balance & history.** Annual and sick balances as of the date (from
  `leave_balance`, the as-of calculation — ADR-034), plus the engineer's leave history.
- **FR-PE7 — Facts.** Contact (email, phone, address), banking (bank, BSB, account, name), employment
  (start, level, monthly salary, emergency contact) — each the latest-read fact from its
  `engineer_*_current` view.
- **FR-PE8 — Role/level history.** The engineer's level over time (the `engineer_role` versions), so a
  promotion is visible as a dated change.
- **FR-PE9 — Contextual actions.** Promote (`Promote`), Take leave (`TakeLeave`), Roll off
  (`RollOff`), Terminate (`TerminateEmployment`), and edit Contact / Banking / Emergency
  (`UpdateContactDetails` / `UpdateBankingDetails` / `UpdateEmergencyContact`) — umbrella FR-U5.

## 4. Acceptance

- The roster lists exactly those employed on the date; scrubbing past a hire/termination date adds or
  removes the person.
- Opening an engineer, then scrubbing, flips allocation rows between active/ended, re-computes the leave
  balance, and re-targets the timesheet to the new week, with no reload.
- Promoting with a future effective date is reflected in the role history and, once the as-of date
  crosses it, in the header level and day rate (PRD FR-3).
