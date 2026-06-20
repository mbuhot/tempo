---
id: P2-T01
phase: 2
title: v1-wide schema migrations
status: done
depends_on: [P0-T04, P1-T01]
parallelizable_with: []
agent: workflow
---

# P2-T01 — v1-wide schema migrations

## Objective
Author the numbered SQL migrations that build the **v1-wide** schema — identity tables plus the
eight fact tables, with `allocation` carrying the denormalized `day_rate` (the "before" generation).

## References
- `ARCHITECTURE.md` §4 (full DDL), §7 (the v1 shape: `allocation.day_rate`)
- `DECISIONS.md` ADR-004, ADR-007, ADR-008, ADR-009

## Work
- [ ] `priv/migrations/001_init.sql` — first statement `CREATE EXTENSION IF NOT EXISTS btree_gist;`
      (verified required by spike P1-T01: `WITHOUT OVERLAPS` builds a GiST exclusion PK, and
      `int + daterange` keys otherwise fail with "integer has no default operator class for access
      method gist"). Then the identity tables `engineer`, `client`.
- [ ] `priv/migrations/002_facts.sql` — `employment`, `engineer_role`, `rate_card`, `contract`,
      `project`, `allocation` (**with** `day_rate`), `leave`, `timesheet` — temporal PKs +
      `PERIOD` FKs exactly as in ARCHITECTURE §4.
- [ ] Apply via the runner; confirm all constraints are created.

## Acceptance
- `gleam run -m tempo/migrate` applies cleanly from empty; every table + `WITHOUT OVERLAPS` /
  `PERIOD`-FK constraint exists.

## Notes
This is the source DDL the constraint tests (P2-T02) and seed (P2-T03) build on. Use the exact column
names from ARCHITECTURE §4 so generated code stays stable.
