---
id: P3
title: Data access & API
type: phase
depends_on_phases: [P2]
---

# Phase 3 — Data access & API

> Static phase overview. Live status is in each task file's frontmatter, not here.

## Goal

Build the typed pipeline from database to JSON: Squirrel queries → shared types + codecs → Wisp API,
with query, codec, and API tests (TDD layers 3–4). End-to-end types hold from column to contract.

## Tasks

| Task | Title | Parallelizable |
|---|---|---|
| P3-T01 | Squirrel queries (board, timesheet) | first |
| P3-T02 | Shared types + JSON codecs | with T01 |
| P3-T03 | Codec round-trip tests | after T02 |
| P3-T04 | As-of query tests | after T01, seed |
| P3-T05 | Wisp JSON API | after T01, T02 |
| P3-T06 | API integration tests | after T05 |

## Exit criteria

- Squirrel-generated `sql.gleam` compiles; queries use the range-decomposition boundary.
- Shared types compile on **both** targets; round-trip tests green.
- As-of query tests return exact expected rows for fixed dates.
- API endpoints return correct JSON; an integrity-violating timesheet write surfaces as an error.
