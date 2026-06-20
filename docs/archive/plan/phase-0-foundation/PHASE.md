---
id: P0
title: Foundation & tooling
type: phase
depends_on_phases: []
---

# Phase 0 — Foundation & tooling

> Static phase overview. Live status is in each task file's frontmatter, not here.

## Goal

Stand up the minimum scaffolding every later phase needs: dependencies, the dual-target module
layout, a running PG19 with a connection pool, a migration runner, and skeletal Playwright + CI
harnesses. No product behaviour yet.

## Tasks

| Task | Title | Parallelizable |
|---|---|---|
| P0-T01 | Add Gleam dependencies | with T05 |
| P0-T02 | Module structure (shared/server/client) | after T01 |
| P0-T03 | PG19 provisioning + pog pool | with T01 |
| P0-T04 | Migration runner + `schema_migrations` | after T02, T03 |
| P0-T05 | Playwright harness skeleton | with T01 |
| P0-T06 | CI skeleton | after T03 |

## Exit criteria

- `gleam build` and `gleam test` run green on the empty skeleton.
- A local PG19 instance is reachable; the pool connects.
- The migration runner applies an empty migration set and records it.
- `npx playwright test` runs a trivial smoke test.
- CI runs on push (provision PG19 + `gleam test`).
