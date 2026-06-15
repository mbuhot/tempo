---
title: Tempo Delivery Plan
type: plan
status: active
phases: 7
---

# Tempo — Delivery Plan

Sequenced delivery plan for the PG19 temporal-staffing demo. Design lives in the repo-root
`PRD.md`, `ARCHITECTURE.md`, and `DECISIONS.md`; this plan turns it into ordered, fan-out-friendly
work.

## Hierarchy

```
plan/
  PLAN.md            ← you are here (static overview)
  phase-N-*/
    PHASE.md         ← phase goal + task list (static)
    PN-TNN-*.md      ← one task = one file; status lives in its frontmatter
```

Three levels: **Plan → Phases → Tasks**. A task is the unit of fan-out.

## Status model (designed for concurrent agents)

- **Status is tracked only in each task file's frontmatter** (`status:` field).
- **There is no central index or state file.** `PLAN.md` and every `PHASE.md` are *static
  descriptions* and are never updated with live progress. Overall progress is derived by *reading*
  task-file frontmatter, never by writing to one shared file — so parallel agents never contend.
- The **only writer** of a task's `status` is the single agent executing that task, editing **only
  that task's file**.

### Status vocabulary

| status | meaning |
|---|---|
| `todo` | not started |
| `in_progress` | claimed and being worked |
| `blocked` | cannot proceed (record why in the file body) |
| `review` | implementation complete, awaiting verification |
| `done` | verified complete (acceptance criteria met) |

Lifecycle: `todo → in_progress → review → done` (`blocked` from any state).

## Dependency & scheduling model

- Each task declares `depends_on: [<task-ids>]` in frontmatter. An agent may **start a task only
  when every dependency is `done`**.
- Tasks with disjoint dependencies and no shared output files may run **concurrently**;
  `parallelizable_with:` is an advisory hint for the orchestrator.
- Phases are sequential by default (`depends_on_phases`), but a downstream phase's independent tasks
  may begin once their specific cross-phase dependencies are `done` — schedule by task, not by phase.

## Phase sequence

| Phase | Goal | Depends on |
|---|---|---|
| **P0 — Foundation & tooling** | deps, module structure, PG19 + DB pool, migration runner, Playwright & CI skeletons | — |
| **P1 — Spikes** | de-risk PG19 temporal DDL, Squirrel ranges, `FOR PORTION OF`, temporal upsert | P0 |
| **P2 — Schema (v1-wide), constraints, seed** | v1 migrations, temporal-constraint tests, deterministic seed | P0, P1 |
| **P3 — Data access & API** | Squirrel queries, shared types + codecs, Wisp JSON API, query/codec/API tests | P2 |
| **P4 — UI & e2e** | Lustre slider, org board, timesheet view; Playwright suite (against v1-wide) | P3 |
| **P5 — Migration to v2-split** | coalescing migration, migration oracle, same Playwright suite green on both tags | P4 |
| **P6 — CI & rehearsal** | full CI (both tags), git tags, demo run-book, legibility pass | P5 |

## Conventions

- Gleam style and TDD per the repo's `CLAUDE.md` (`assert == expected`, `todo` stubs, narrow facts,
  `gleam add` for deps). Behaviour-driven tests; no assertions on DOM/CSS internals.
- Task files reference design-doc sections rather than duplicating DDL/SQL — keep them readable.
- Commit per task (small, WHAT-focused messages); commit only when the human asks.
