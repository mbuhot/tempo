---
id: P0-T06
phase: 0
title: CI skeleton
status: done
depends_on: [P0-T03]
parallelizable_with: []
agent: workflow
---

# P0-T06 — CI skeleton

## Objective
Extend the existing GitHub Actions workflow to provision PG19 and run `gleam test`, so every later
phase lands on green CI. Full both-tags pipeline comes in P6-T01.

## References
- `.github/workflows/test.yml` (existing)
- `ARCHITECTURE.md` §10 (provisioning / CI)

## Work
- [ ] Add a PostgreSQL 19 service (or container step) to the workflow.
- [ ] Steps: checkout → set up Gleam/Erlang → start PG19 → `gleam run -m tempo/migrate` →
      `gleam test`.
- [ ] Wire DB connection via CI env matching `context.gleam`.

## Acceptance
- CI runs on push and is green on the current skeleton (no product tests yet).

## Notes
Leave Playwright + the migrate-and-re-test (both tags) steps for P6-T01; keep this lean.
