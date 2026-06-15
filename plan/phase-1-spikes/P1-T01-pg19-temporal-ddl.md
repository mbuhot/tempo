---
id: P1-T01
phase: 1
title: Spike — PG19 temporal DDL works
status: done
depends_on: [P0-T03]
parallelizable_with: [P1-T02, P1-T03, P1-T04]
agent: workflow
---

# P1-T01 — Spike: PG19 temporal DDL works

## Objective
Confirm the provisioned PostgreSQL accepts the temporal features the whole design rests on.

## References
- `ARCHITECTURE.md` §4 (schema), §7 (migration), §11.1
- `PRD.md` §1

## Work
- [x] Throwaway SQL: create a table with `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)` over a
      `daterange`.
- [x] Add a `PERIOD` foreign key between two such tables; confirm it rejects a dangling child period.
- [x] Run a `FOR PORTION OF` update and confirm row splitting.
- [x] Run `range_agg(...)` + `unnest(...)` and confirm coalescing semantics.

## Acceptance
- All four behaviours work on the target server, **or** the gap is documented with a concrete
  fallback.

## Finding

**Verdict: WORKS.** All four temporal behaviours verified on PostgreSQL 19beta1.

**Environment.** The DB came from Docker (P0-T03's `docker-compose.yml`): image `postgres:19beta1`
(the first tag tried — `postgres:19beta2` was not needed), container `tempo-db`, reachable on host
port `5434` (user/pass/db all `tempo`). The local Homebrew server is PG17, so PG19 must stay on
Docker as designed. `SELECT version()` →
`PostgreSQL 19beta1 (Debian 19~beta1-1.pgdg13+1) on aarch64-unknown-linux-gnu`.

Verified via a throwaway `/tmp/p1t01_temporal_spike.sql` run over the published port into an
isolated `spike` schema (dropped at the end — no project tables created).

1. **`WITHOUT OVERLAPS` primary key over `daterange`** — works. Two adjacent non-overlapping
   periods for the same key insert fine; an overlapping period is rejected with
   `conflicting key value violates exclusion constraint "..._pkey"`.
2. **`PERIOD` foreign key** — works, and is strict. A child period fully inside the parent is
   accepted; a child period spanning two *adjacent* parent rows is accepted (PG coalesces the
   parent's periods for containment); a child for a key with no parent row is rejected; a child
   whose tail extends past the parent's end is rejected
   (`violates foreign key constraint ...`). This is exactly PRD FR-5 "associations cannot outlive
   employment".
3. **`FOR PORTION OF` update** — works. A single year-long `rate_card` row, updated
   `FOR PORTION OF valid_at FROM '2026-07-01' TO '2027-01-01'`, split cleanly into
   `[2026-01-01,2026-07-01) @ 1000.00` and `[2026-07-01,2027-01-01) @ 1200.00` (only the targeted
   sub-period changed). PRD FR-6 confirmed.
4. **`range_agg(...)` + `unnest(...)` coalescing** — works. Two rate-only-fragmented adjacent
   periods coalesced into `[2026-01-01,2026-05-01)`; a genuine gap (no June row) was preserved as a
   separate `[2026-07-01,2026-09-01)` range. This is the exact `v1-wide → v2-split` coalescing from
   ARCHITECTURE §7.

**Required dependency (action item for the migration author, not a blocker).** `WITHOUT OVERLAPS`
builds the PK as a GiST-backed exclusion constraint, and GiST has no default operator class for a
plain `integer` scalar key. Every table in ARCHITECTURE §4 keys on `int + daterange`, so the very
first `CREATE TABLE` fails with
`data type integer has no default operator class for access method "gist"` until the extension is
installed. Fix is one line at the top of `001_init.sql`: `CREATE EXTENSION IF NOT EXISTS btree_gist;`
(version 1.9 is available in the image; the spike installed it into the `tempo` DB — idempotent,
harmless, and exactly what the real schema needs). No code/SQL fallback is required.
