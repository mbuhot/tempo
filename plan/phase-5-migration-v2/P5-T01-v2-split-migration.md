---
id: P5-T01
phase: 5
title: v2-split migration (coalesce)
status: done
depends_on: [P4-T04]
parallelizable_with: []
agent: workflow
---

# P5-T01 — v2-split migration (coalesce)

## Objective
The centerpiece migration: drop the denormalized `allocation.day_rate` and coalesce the fragmented
allocation rows with `range_agg`, validated by the existing constraints inside one transaction.

## References
- `ARCHITECTURE.md` §7 (the migration SQL), §4
- `DECISIONS.md` ADR-007

## Work
- [ ] `priv/migrations/010_split_allocation.sql` — create slim `allocation`, `range_agg`-coalesce
      grouping by `(engineer_id, project_id, fraction)`, drop old, rename, all in `BEGIN/COMMIT`.
- [ ] Confirm the new `WITHOUT OVERLAPS` PK + PERIOD FKs validate the transform (a deliberately bad
      coalesce rolls back).
- [ ] Apply on top of the v1 seed via the runner.

## Acceptance
- Migration applies in one transaction on seeded v1 data; constraints accept the result; `day_rate`
  column is gone from `allocation`.

## Notes
This runs against the **migrated v1 seed** — the same data, restructured. No new seed.
