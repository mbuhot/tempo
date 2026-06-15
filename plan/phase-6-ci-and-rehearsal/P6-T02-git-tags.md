---
id: P6-T02
phase: 6
title: Git tags v1-wide / v2-split
status: todo
depends_on: [P6-T01]
parallelizable_with: []
agent: unassigned
---

# P6-T02 — Git tags `v1-wide` / `v2-split`

## Objective
Mark the two schema generations as checkout points, each an internally-consistent tree.

## References
- `ARCHITECTURE.md` §8; `PRD.md` §7 beat 6

## Work
- [ ] Ensure the commit tagged `v1-wide` has the v1 schema + generated `sql.gleam` + shared types all
      consistent (rate from the cached column).
- [ ] Ensure the commit tagged `v2-split` has the migration applied state: derived-rate queries +
      regenerated code.
- [ ] Create both annotated tags; verify a clean `git checkout <tag>` builds and runs.

## Acceptance
- `git checkout v1-wide` and `git checkout v2-split` each build, migrate, and serve a working app.

## Notes
Generated code is committed at each tag so the checkout dance needs no live codegen on stage.
