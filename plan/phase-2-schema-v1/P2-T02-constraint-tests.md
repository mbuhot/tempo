---
id: P2-T02
phase: 2
title: Temporal-constraint tests (layer 1)
status: done
depends_on: [P2-T01]
parallelizable_with: [P2-T03]
agent: workflow
---

# P2-T02 — Temporal-constraint tests (TDD layer 1)

## Objective
Prove the **database**, not the app, enforces every temporal rule. Strict TDD: write the failing
assertion first.

## References
- `ARCHITECTURE.md` §10.1
- `PRD.md` FR-5
- `CLAUDE.md` — Gleam Testing (`assert == expected`), Preserving Test Output

## Work
- [ ] `WITHOUT OVERLAPS`: inserting an overlapping `allocation` for the same `(engineer, project)` is
      rejected.
- [ ] `PERIOD` FK rejections: `allocation`/`leave`/`engineer_role` past `employment`; `allocation`
      outside `project`; `project` outside `contract`; `timesheet` against a non-allocated project.
- [ ] `FOR PORTION OF`: updating a `rate_card` sub-range splits into the expected before/during/after
      rows.
- [ ] `range_agg` coalescing: merges adjacent/overlapping ranges and preserves a genuine gap.

## Acceptance
- Each case asserts the exact rejection/result; suite green via `gleam test`.

## Notes
Use small, explicit fixtures (not the full seed). Redirect runner output to a file if large; never
pipe through `head`/`grep` inline.
