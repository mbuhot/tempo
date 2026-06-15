---
id: P5-T03
phase: 5
title: Migration oracle test (layer 2)
status: done
depends_on: [P5-T01]
parallelizable_with: [P5-T02]
agent: workflow
---

# P5-T03 — Migration oracle test (TDD layer 2)

## Objective
Automate the on-stage claim: the board is identical for every date across the v1→v2 migration.

## References
- `ARCHITECTURE.md` §7 (slider as oracle), §10.2

## Work
- [ ] Seed v1; snapshot the board for **every date** in a dense range (e.g. each day across the seed
      span).
- [ ] Apply `010_split_allocation`.
- [ ] Re-snapshot; assert **equal** for every date.
- [ ] Fail loudly with the first differing date if not.

## Acceptance
- Oracle test green: board-equal for all sampled dates pre/post migration.

## Notes
This is the standout automated test — it turns "history is provably intact" into a CI gate.
