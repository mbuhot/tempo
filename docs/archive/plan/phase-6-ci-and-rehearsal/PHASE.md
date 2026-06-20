---
id: P6
title: CI & rehearsal
type: phase
depends_on_phases: [P5]
---

# Phase 6 — CI & rehearsal

> Static phase overview. Live status is in each task file's frontmatter, not here.

## Goal

Make the whole thing reproducible and stage-ready: full CI that runs the suite on both schema tags,
the git tags that mark each generation, a demo run-book, and a legibility pass.

## Tasks

| Task | Title | Parallelizable |
|---|---|---|
| P6-T01 | Full CI (both tags) | first |
| P6-T02 | Git tags `v1-wide` / `v2-split` | after T01 |
| P6-T03 | Demo run-book + clean-checkout dry run | with T01 |
| P6-T04 | Legibility / styling pass | with T01 |

## Exit criteria

- CI: provision PG19 → `gleam test` → build + serve → Playwright on v1-wide → migrate → Playwright on
  v2-split; all green.
- Tags exist with internally-consistent committed code (generated SQL + shared types).
- Run-book maps each of the 7 beats to concrete steps and passes a clean-checkout dry run.
- Board/timesheet are legible from the back of a room.
