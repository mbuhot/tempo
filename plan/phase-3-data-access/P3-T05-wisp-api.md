---
id: P3-T05
phase: 3
title: Wisp JSON API
status: done
depends_on: [P3-T01, P3-T02]
parallelizable_with: [P3-T04]
agent: workflow
---

# P3-T05 — Wisp JSON API

## Objective
Expose the board and timesheet behind a small JSON API, mapping Squirrel rows → shared types → JSON.

## References
- `ARCHITECTURE.md` §2, §3, §5
- `PRD.md` FR-1, FR-7

## Work
- [ ] `GET /api/board?as_of=YYYY-MM-DD` → `BoardSnapshot`.
- [ ] `GET /api/timesheet?engineer=ID&day=YYYY-MM-DD` → `TimesheetDay`.
- [ ] `POST /api/timesheet` → upsert a line (P1-T04 approach); map a PERIOD-FK violation to a clean
      4xx with a typed error body.
- [ ] Serve `priv/static` (client bundle + `index.html`) and wire the pool from `context.gleam`.

## Acceptance
- Endpoints return correct JSON for seeded inputs; an invalid timesheet write returns a 4xx, not a
  500.

## Notes
Handlers are thin: query → map to shared type → encode. Keep mapping in one place.
