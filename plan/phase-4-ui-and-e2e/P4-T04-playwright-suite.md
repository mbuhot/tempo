---
id: P4-T04
phase: 4
title: Playwright suite (one test per beat)
status: done
depends_on: [P4-T02, P4-T03]
parallelizable_with: []
agent: workflow
---

# P4-T04 — Playwright suite (one test per beat)

## Objective
The behaviour-driven e2e suite covering every demo beat, running against **v1-wide**. This same suite
must later pass unchanged on v2-split (P5-T04).

## References
- `ARCHITECTURE.md` §10.5; `PRD.md` §7
- `DECISIONS.md` ADR-013
- `CLAUDE.md` — LiveView Testing (behaviour-driven; no DOM/CSS assertions)

## Work
- [ ] Scrub to a date → expected engineers/projects/clients are visible.
- [ ] Scrub across a seeded future promotion → level and charge rate increase.
- [ ] Scrub onto a leave period → engineer shows "On leave".
- [ ] Timesheet: scrub to a day → only allocated projects offered; enter hours → reload → persisted.
- [ ] Negative: a rolled-off project is not offered for logging.
- [ ] Run against a fresh **v1-seeded** PG19 via the harness.

## Acceptance
- All beat tests green against v1-wide; assertions reference only user-visible content.

## Notes
Do **not** assert on the rate's source or any table shape — only on what the user sees, so the suite
survives the P5 migration verbatim.
