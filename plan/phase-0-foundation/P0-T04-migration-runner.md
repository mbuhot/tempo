---
id: P0-T04
phase: 0
title: Migration runner + schema_migrations
status: todo
depends_on: [P0-T02, P0-T03]
parallelizable_with: []
agent: unassigned
---

# P0-T04 — Migration runner + `schema_migrations`

## Objective
A minimal, hand-written-SQL migration runner that applies numbered files in order and records what
ran. No migration framework.

## References
- `ARCHITECTURE.md` §8 (migrations mechanism)
- `CLAUDE.md` — Gleam style

## Work
- [ ] Create `priv/migrations/` (empty for now).
- [ ] Implement `src/tempo/server/migrate.gleam`: read `priv/migrations/NNN_*.sql` sorted, apply each
      pending file inside a transaction, record `schema_migrations(version, applied_at)`.
- [ ] Make it runnable as `gleam run -m tempo/migrate`.
- [ ] Idempotent: re-running applies nothing when up to date.

## Acceptance
- Running against an empty migration set creates `schema_migrations` and reports "nothing to apply";
  a second run is a no-op.

## Notes
Keep it ~50 lines. It must run a raw `.sql` file as-is (the migrations contain temporal DDL).
