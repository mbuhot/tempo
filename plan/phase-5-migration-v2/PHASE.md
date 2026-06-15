---
id: P5
title: Migration to v2-split
type: phase
depends_on_phases: [P4]
---

# Phase 5 — Migration to v2-split

> Static phase overview. Live status is in each task file's frontmatter, not here.

## Goal

Perform the schema-evolution centerpiece: the coalescing migration that removes the denormalized
`allocation.day_rate` and derives the charge rate from `engineer_role × rate_card`. Prove correctness
two ways — a DB-level migration oracle and the **unchanged** Playwright suite staying green.

## Tasks

| Task | Title | Parallelizable |
|---|---|---|
| P5-T01 | v2-split migration (coalesce) | first |
| P5-T02 | Derive rate; regenerate queries/types | after T01 |
| P5-T03 | Migration oracle test | after T01 |
| P5-T04 | Same Playwright suite on both tags | after T02, T03 |

## Exit criteria

- Migration applies in one transaction; new constraints validate the transform.
- Charge rate now derives from role × rate_card with **no change to shared types / user-visible
  behaviour**.
- Migration oracle: board equal for every date across the migration.
- The Playwright suite from P4 passes **unmodified** against v2-split.
