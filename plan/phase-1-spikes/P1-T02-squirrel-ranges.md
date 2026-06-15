---
id: P1-T02
phase: 1
title: Spike — Squirrel daterange decomposition
status: todo
depends_on: [P0-T01, P0-T03]
parallelizable_with: [P1-T01, P1-T03, P1-T04]
agent: unassigned
---

# P1-T02 — Spike: Squirrel ↔ `daterange` decomposition

## Objective
Verify the range-decomposition boundary lets Squirrel generate clean typed code without depending on
`daterange`/`datemultirange` mapping.

## References
- `ARCHITECTURE.md` §6 (Squirrel integration), §11.2
- `DECISIONS.md` ADR-011

## Work
- [ ] Author a tiny `.sql` query that SELECTs `lower(valid_at) AS valid_from`,
      `upper(valid_at) AS valid_to` (plain `date`) from a temporal table.
- [ ] Author a write that accepts a range built in SQL: `daterange($from, $to, '[)')`.
- [ ] Run `gleam run -m squirrel`; confirm generated functions type `date` params/returns cleanly.
- [ ] Round-trip a value through generated code.

## Acceptance
- Generated code compiles and round-trips, confirming ADR-011, **or** document the needed adjustment.

## Finding
_record outcome here_
