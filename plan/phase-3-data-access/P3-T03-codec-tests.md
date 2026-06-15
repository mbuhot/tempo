---
id: P3-T03
phase: 3
title: Codec round-trip tests (layer 4)
status: todo
depends_on: [P3-T02]
parallelizable_with: [P3-T04]
agent: unassigned
---

# P3-T03 — Codec round-trip tests (TDD layer 4)

## Objective
Guarantee `encode |> decode == value` for every shared API type.

## References
- `ARCHITECTURE.md` §10.4
- `CLAUDE.md` — Gleam Testing

## Work
- [ ] One round-trip test per shared type with explicit, deterministic values.
- [ ] Include edge cases: on-leave row (project/client absent), zero-hours timesheet line.
- [ ] Assert exact equality (`assert decoded == original`).

## Acceptance
- All round-trip tests green; a deliberately broken decoder fails them (sanity check).

## Notes
Pure Gleam — runs on both targets. No DB needed.
