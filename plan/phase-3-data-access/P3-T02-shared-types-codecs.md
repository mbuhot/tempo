---
id: P3-T02
phase: 3
title: Shared types + JSON codecs
status: todo
depends_on: [P0-T02]
parallelizable_with: [P3-T01]
agent: unassigned
---

# P3-T02 — Shared types + JSON codecs

## Objective
Define the API contract types and their JSON encoders/decoders in `shared`, compiled to both targets.

## References
- `ARCHITECTURE.md` §2, §3
- `DECISIONS.md` ADR-005

## Work
- [ ] `src/tempo/shared/types.gleam` — `BoardSnapshot`, `BoardRow` (engineer, level, project,
      client, fraction, day_rate, on-leave kind), `TimesheetDay`, `TimesheetLine`, `AsOf`, etc.
- [ ] `src/tempo/shared/codecs.gleam` — `gleam/json` encoders + `gleam/dynamic/decode` decoders for
      each type.
- [ ] Confirm the module compiles for both Erlang and JS (no target-specific deps).

## Acceptance
- `shared` builds on both targets; types model exactly what the board + timesheet views need.

## Notes
Design these to be **stable across v1→v2** — user-visible shape must not change when the rate source
changes (ADR-013). Charge rate is a value in the row, not "where it came from".
