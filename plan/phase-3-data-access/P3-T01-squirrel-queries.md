---
id: P3-T01
phase: 3
title: Squirrel queries (board, timesheet)
status: todo
depends_on: [P2-T01, P1-T02, P1-T03, P1-T04]
parallelizable_with: [P3-T02]
agent: unassigned
---

# P3-T01 — Squirrel queries (board, timesheet)

## Objective
Author the `.sql` query sources and generate typed Gleam, using the range-decomposition boundary.

## References
- `ARCHITECTURE.md` §5 (key queries), §6 (Squirrel boundary)
- `DECISIONS.md` ADR-011

## Work
- [ ] `src/tempo/server/sql/board_as_of.sql` — the as-of org board (leave suppresses allocations;
      returns `valid_from`/`valid_to` as `date`s).
- [ ] `src/tempo/server/sql/timesheet_form.sql` — an engineer's allocations as of a day (+ existing
      hours).
- [ ] `src/tempo/server/sql/timesheet_write.sql` — insert (using the P1-T04 re-entry approach).
- [ ] Any helper queries (e.g. charge-rate-as-of) as needed.
- [ ] `gleam run -m squirrel`; commit generated `sql.gleam`.

## Acceptance
- Generated functions compile; the FOR-PORTION-OF rate edit is reachable (generated or `pog`
  fallback per P1-T03).

## Notes
Keep SELECT lists returning plain scalars/`date`s so shared types stay simple.

Carried from Phase 1 spikes:
- Squirrel only discovers `.sql` files in a dir literally named `sql` (use `src/tempo/server/sql/`).
- Codegen needs a live DB connection, e.g.
  `DATABASE_URL="postgres://tempo:tempo@127.0.0.1:5434/tempo" gleam run -m squirrel`.
- `FOR PORTION OF` reports `UPDATE 1` even when it splits a row into two — never rely on the
  affected-row count to detect a split.
