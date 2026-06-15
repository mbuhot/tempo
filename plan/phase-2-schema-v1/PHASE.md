---
id: P2
title: Schema (v1-wide), constraints, seed
type: phase
depends_on_phases: [P0, P1]
---

# Phase 2 — Schema (v1-wide), constraints, seed

> Static phase overview. Live status is in each task file's frontmatter, not here.

## Goal

Create the **v1-wide** schema (the "before" generation, with the denormalized `allocation.day_rate`),
prove the temporal constraints actually enforce the rules, and build the deterministic seed that is
the single source of truth for every later test and demo beat.

## Tasks

| Task | Title | Parallelizable |
|---|---|---|
| P2-T01 | v1-wide migrations | first |
| P2-T02 | Temporal-constraint tests | after T01 |
| P2-T03 | Seed dataset (v1, deterministic) | after T01 (with T02) |

## Exit criteria

- All v1 tables exist via numbered migrations the runner applies cleanly.
- Constraint tests (TDD layer 1) are green: every `WITHOUT OVERLAPS` / `PERIOD`-FK violation is
  rejected; `FOR PORTION OF` and `range_agg` behave as specified.
- Seed loads, satisfies the seed invariant (`day_rate == rate_card[level]`), and exercises every
  demo beat.
