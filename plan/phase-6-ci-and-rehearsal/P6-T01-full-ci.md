---
id: P6-T01
phase: 6
title: Full CI (both tags)
status: todo
depends_on: [P5-T04]
parallelizable_with: [P6-T03, P6-T04]
agent: unassigned
---

# P6-T01 — Full CI (both tags)

## Objective
The complete pipeline: all Gleam tests plus the Playwright suite on **both** schema states.

## References
- `ARCHITECTURE.md` §10 (provisioning / CI)
- `DECISIONS.md` ADR-013

## Work
- [ ] Extend `.github/workflows/test.yml`: provision PG19 → `gleam test` (layers 1–4) → build client
      + start server → seed v1 + Playwright → apply migration → run the **same** Playwright again.
- [ ] Cache npm + Playwright browsers for speed.
- [ ] Fail the job if either Playwright pass is red.

## Acceptance
- CI green end to end, including both Playwright passes and the migration oracle.

## Notes
This is the gate that protects the live demo from regressions.
