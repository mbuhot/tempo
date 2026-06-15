---
id: P5-T04
phase: 5
title: Same Playwright suite green on both tags
status: todo
depends_on: [P5-T02, P5-T03]
parallelizable_with: []
agent: unassigned
---

# P5-T04 — Same Playwright suite green on both tags

## Objective
Prove at the UI layer that the migration changed nothing observable: the **unmodified** P4 suite
passes against v2-split.

## References
- `DECISIONS.md` ADR-013; `ARCHITECTURE.md` §10.5

## Work
- [ ] Run the P4-T04 Playwright suite against a v1-seeded-then-migrated (v2-split) PG19.
- [ ] Confirm **zero** changes to the spec files were needed.
- [ ] If anything fails, fix the implementation (not the tests) — a needed test change means
      behaviour changed.

## Acceptance
- The identical suite is green on both v1-wide and v2-split; no spec edits.

## Notes
Pairs with the DB oracle (P5-T03): data parity + UI parity together.
