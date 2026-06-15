---
id: P1-T01
phase: 1
title: Spike — PG19 temporal DDL works
status: todo
depends_on: [P0-T03]
parallelizable_with: [P1-T02, P1-T03, P1-T04]
agent: unassigned
---

# P1-T01 — Spike: PG19 temporal DDL works

## Objective
Confirm the provisioned PostgreSQL accepts the temporal features the whole design rests on.

## References
- `ARCHITECTURE.md` §4 (schema), §7 (migration), §11.1
- `PRD.md` §1

## Work
- [ ] Throwaway SQL: create a table with `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)` over a
      `daterange`.
- [ ] Add a `PERIOD` foreign key between two such tables; confirm it rejects a dangling child period.
- [ ] Run a `FOR PORTION OF` update and confirm row splitting.
- [ ] Run `range_agg(...)` + `unnest(...)` and confirm coalescing semantics.

## Acceptance
- All four behaviours work on the target server, **or** the gap is documented with a concrete
  fallback.

## Finding
_record outcome here: works / fallback needed (details)_
