---
id: P4-T03
phase: 4
title: My-timesheet view
status: todo
depends_on: [P4-T01]
parallelizable_with: [P4-T02]
agent: unassigned
---

# P4-T03 — My-timesheet view

## Objective
The interactive write path: pick an engineer, scrub to a day, see allocated projects, enter and save
hours.

## References
- `PRD.md` FR-7, §7 beat 5
- `ARCHITECTURE.md` §5
- `DECISIONS.md` ADR-010

## Work
- [ ] Engineer selector + day (driven by the slider/date control).
- [ ] Fetch `GET /api/timesheet?engineer&day`; render one input per allocated project (with fraction);
      show "On leave — nothing to log" on a leave day.
- [ ] Submit → `POST /api/timesheet`; reflect saved hours; surface a rejected write as a friendly
      message.

## Acceptance
- Only allocated projects are offered; entered hours persist across reload; a leave day shows the
  leave state.

## Notes
The UI naturally only offers valid projects; the PERIOD-FK is the backstop, demonstrated by the
negative Playwright case (P4-T04).
