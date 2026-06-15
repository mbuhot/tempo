---
id: P4
title: UI & end-to-end
type: phase
depends_on_phases: [P3]
---

# Phase 4 — UI & end-to-end

> Static phase overview. Live status is in each task file's frontmatter, not here.

## Goal

Build the Lustre SPA — the time slider, the org board, and the interactive timesheet — and the
Playwright suite (TDD layer 5) that covers every demo beat, running against **v1-wide**.

## Tasks

| Task | Title | Parallelizable |
|---|---|---|
| P4-T01 | Client skeleton + build pipeline | first |
| P4-T02 | Time slider + org board view | after T01 |
| P4-T03 | My-timesheet view | after T01 (with T02) |
| P4-T04 | Playwright suite (one test per beat) | after T02, T03 |

## Exit criteria

- Client bundle builds to `priv/static` and is served by Wisp.
- Scrubbing the slider re-renders the org board as of the selected date; leave shows "On leave".
- The timesheet view offers only allocated projects and persists entered hours.
- Playwright suite green against v1-wide; assertions are behaviour-only (no DOM/CSS internals).
