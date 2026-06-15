---
id: P1-T03
phase: 1
title: Spike — Squirrel FOR PORTION OF
status: todo
depends_on: [P0-T01, P0-T03]
parallelizable_with: [P1-T01, P1-T02, P1-T04]
agent: unassigned
---

# P1-T03 — Spike: Squirrel ↔ `FOR PORTION OF`

## Objective
Confirm a `FOR PORTION OF` update can be expressed through Squirrel, or determine the fallback.

## References
- `ARCHITECTURE.md` §11.3
- `PRD.md` FR-6

## Work
- [ ] Author a `.sql` `UPDATE … FOR PORTION OF valid_at FROM $from TO $to SET …` against a temporal
      table.
- [ ] Run `gleam run -m squirrel`; confirm PG prepares it and Squirrel emits a usable function.
- [ ] If Squirrel cannot introspect it, prototype the same statement as a hand-written `pog` query.

## Acceptance
- Either a generated function or a documented `pog` fallback exists for `FOR PORTION OF`.

## Finding
_record outcome here: squirrel-ok / pog-fallback (details)_
