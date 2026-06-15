---
id: P1-T04
phase: 1
title: Spike — Temporal upsert for timesheet
status: todo
depends_on: [P0-T03]
parallelizable_with: [P1-T01, P1-T02, P1-T03]
agent: unassigned
---

# P1-T04 — Spike: Temporal upsert for timesheet

## Objective
Determine the re-entry (upsert) approach for `timesheet`, whose `WITHOUT OVERLAPS` PK is an
exclusion constraint that `ON CONFLICT` cannot target.

## References
- `ARCHITECTURE.md` §5 (impl note on upsert), §11.4

## Work
- [ ] Confirm `INSERT … ON CONFLICT` fails / is unsupported against the `WITHOUT OVERLAPS` PK.
- [ ] Validate the chosen fallback: delete-then-insert within a transaction
      (`DELETE … WHERE work_day @> $day; INSERT …`), or a supplemental unique index for the upsert
      path.
- [ ] Pick one and note it for P3-T05 (timesheet write).

## Acceptance
- A working, documented re-entry approach for a single `(engineer, project, day)` timesheet row.

## Finding
_record outcome here: delete-then-insert / supplemental-unique (details)_
