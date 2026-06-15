---
id: P3-T04
phase: 3
title: As-of query tests (layer 3)
status: done
depends_on: [P3-T01, P2-T03]
parallelizable_with: [P3-T03]
agent: workflow
---

# P3-T04 — As-of query tests (TDD layer 3)

## Objective
Verify the temporal queries return exactly the right rows for fixed dates against the seed.

## References
- `ARCHITECTURE.md` §5, §10.3
- `PRD.md` FR-1, FR-2, FR-3, FR-4

## Work
- [ ] Board as-of a **past** date → expected engineers/projects/clients/levels/rates.
- [ ] Board as-of a date **inside a leave** → that engineer shows on-leave, allocations suppressed.
- [ ] Board as-of a **future** date past a seeded promotion → new level + new charge rate.
- [ ] Timesheet-form query for an engineer/day → only allocated projects (empty on a leave day).

## Acceptance
- Each test asserts the exact expected result set (deterministic seed values).

## Notes
These pin the *data* behaviour the Playwright suite later asserts via the UI.
