---
id: P0-T03
phase: 0
title: PG19 provisioning + pog pool
status: done
depends_on: []
parallelizable_with: [P0-T01]
agent: workflow
---

# P0-T03 — PG19 provisioning + pog pool

## Objective
Provide a reproducible local PostgreSQL 19 instance and a `pog` connection pool the app and tests
share.

## References
- `ARCHITECTURE.md` §1, §9, §11 (PG19 availability spike — coordinate with P1-T01)
- `PRD.md` §11 (dependencies/risks)

## Work
- [ ] Add a `docker-compose.yml` (or scripted) **PostgreSQL 19** service (beta/RC or temporal-patched
      build) with a fixed dev database + credentials via env.
- [ ] Implement `src/tempo/server/context.gleam` exposing a configured pog pool.
- [ ] Add a connection smoke check (`SELECT 1`) runnable via the test suite.
- [ ] Document the one-liner to start the DB in the run-book stub.

## Acceptance
- `docker compose up` (or the script) yields a reachable PG19; the pool connects; smoke check passes.

## Notes
This is the prerequisite for the P1 spikes and all DB tests. Confirm the server reports a 19.x
version.
