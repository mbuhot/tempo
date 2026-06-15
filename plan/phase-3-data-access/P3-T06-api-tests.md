---
id: P3-T06
phase: 3
title: API integration tests
status: todo
depends_on: [P3-T05]
parallelizable_with: []
agent: unassigned
---

# P3-T06 — API integration tests

## Objective
Exercise the HTTP layer end to end (handler + DB + codecs) against the seed.

## References
- `ARCHITECTURE.md` §10 (layers 1–4), §5
- `PRD.md` FR-1, FR-5, FR-7

## Work
- [ ] `GET /api/board` for fixed dates → decoded `BoardSnapshot` matches expected.
- [ ] `GET /api/timesheet` → expected lines; empty on a leave day.
- [ ] `POST /api/timesheet` valid → persisted and reflected on re-GET.
- [ ] `POST /api/timesheet` against a non-allocated project → 4xx typed error (DB rejected it).

## Acceptance
- All API tests green; the negative write proves the PERIOD-FK backstop surfaces as a clean error.

## Notes
Reuse the shared codecs to decode responses — this also dogfoods the contract.
