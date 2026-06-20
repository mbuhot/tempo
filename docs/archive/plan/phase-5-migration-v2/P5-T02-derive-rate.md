---
id: P5-T02
phase: 5
title: Derive rate; regenerate queries/types
status: done
depends_on: [P5-T01]
parallelizable_with: [P5-T03]
agent: workflow
---

# P5-T02 — Derive rate; regenerate queries/types

## Objective
Source the charge rate from `engineer_role × rate_card` (no longer the cached column) while keeping
the shared types and user-visible behaviour **unchanged**.

## References
- `ARCHITECTURE.md` §5, §6; `DECISIONS.md` ADR-009, ADR-013

## Work
- [ ] Update `board_as_of.sql` (and any rate query) to join role × rate_card for the rate instead of
      reading `allocation.day_rate`.
- [ ] `gleam run -m squirrel`; commit regenerated `sql.gleam`.
- [ ] Confirm `shared` types are untouched (charge rate is still just a value on the row).

## Acceptance
- Queries compile; board output is identical to v1 for the same dates; no change to `shared`.

## Notes
If `shared` needs to change, the redesign is leaking implementation into the contract — stop and
reconsider (ADR-013).
