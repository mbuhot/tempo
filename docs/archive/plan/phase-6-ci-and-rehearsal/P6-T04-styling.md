---
id: P6-T04
phase: 6
title: Legibility / styling pass
status: done
depends_on: [P4-T02, P4-T03]
parallelizable_with: [P6-T01, P6-T03]
agent: workflow
---

# P6-T04 — Legibility / styling pass

## Objective
Make the board and timesheet readable from the back of a room — minimal, high-contrast styling only.

## References
- `PRD.md` §10 (minimal styling), §2 (legibility)

## Work
- [ ] Large type, high contrast, clear column layout for the board.
- [ ] Make the slider and current date prominent.
- [ ] Visually distinguish on-leave rows and the current/future boundary.
- [ ] Sanity check Playwright still green (assertions are behaviour-only, so styling must not break
      them).

## Acceptance
- Board/timesheet are legible at a glance on a projector; e2e suite unaffected.

## Notes
Keep it minimal — polish is explicitly a non-goal beyond legibility.
