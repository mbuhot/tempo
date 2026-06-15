---
id: P4-T02
phase: 4
title: Time slider + org board view
status: todo
depends_on: [P4-T01]
parallelizable_with: [P4-T03]
agent: unassigned
---

# P4-T02 — Time slider + org board view

## Objective
The hero interaction: a date slider that re-renders the whole org board "as of" the selected date.

## References
- `PRD.md` FR-1, FR-2, FR-3, FR-4; `PRD.md` §7 beats 1–4
- `ARCHITECTURE.md` §5

## Work
- [ ] Date slider spanning the seed's past→future range; debounced `GET /api/board?as_of=…` on change.
- [ ] Render engineers with level, project(s), client(s), fraction, and charge rate.
- [ ] Render an on-leave engineer distinctly ("On leave: <kind>").
- [ ] Ensure future-dated facts (a promotion) appear when scrubbed past their start.

## Acceptance
- Scrubbing visibly changes the board; past/future/leave all render correctly from real API data.

## Notes
Legibility matters (back of room) — but no assertions on styling. Keep view functions small (SLAP).
