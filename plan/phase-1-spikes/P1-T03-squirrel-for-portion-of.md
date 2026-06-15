---
id: P1-T03
phase: 1
title: Spike — Squirrel FOR PORTION OF
status: done
depends_on: [P0-T01, P0-T03]
parallelizable_with: [P1-T01, P1-T02, P1-T04]
agent: workflow
---

# P1-T03 — Spike: Squirrel ↔ `FOR PORTION OF`

## Objective
Confirm a `FOR PORTION OF` update can be expressed through Squirrel, or determine the fallback.

## References
- `ARCHITECTURE.md` §11.3
- `PRD.md` FR-6

## Work
- [ ] Author a `.sql` `UPDATE … FOR PORTION OF valid_at FROM $from TO $to SET …` against a temporal
      table.
- [ ] Run `gleam run -m squirrel`; confirm PG prepares it and Squirrel emits a usable function.
- [ ] If Squirrel cannot introspect it, prototype the same statement as a hand-written `pog` query.

## Acceptance
- Either a generated function or a documented `pog` fallback exists for `FOR PORTION OF`.

## Finding

**squirrel-ok** — no `pog` fallback needed.

Verified against Docker `postgres:19beta1` (the running `tempo-db` container on host
port 5434; `version()` → `PostgreSQL 19beta1 (Debian 19~beta1-1.pgdg13+1)`).
`19beta2` was not pulled because the docker-compose pin / running container is already
`19beta1` and it satisfies the spike.

Spike SQL (plain `date` params at the boundary, per ARCHITECTURE.md §6):

```sql
UPDATE rate_card
   FOR PORTION OF valid_at FROM $1::date TO $2::date
   SET day_rate = $3
 WHERE level = $4;
```

`gleam run -m squirrel` (squirrel v4.7.0, with `DATABASE_URL` pointing at the PG19
container) prepared the statement and emitted a usable typed function:

```gleam
pub fn spike_rate_card_for_portion_of(
  db: pog.Connection,
  arg_1: Date,        // FROM boundary  ($1::date)
  arg_2: Date,        // TO boundary    ($2::date)
  day_rate: Float,    // SET day_rate   ($3) — named from the target column
  arg_4: Int,         // WHERE level    ($4)
) -> Result(pog.Returned(Nil), pog.QueryError)
```

PG's Parse/Describe round-trip succeeds: the `::date` casts give the FROM/TO params a
type, `$3` is inferred as `numeric` → `Float`, `$4` as `int`. No `RETURNING` clause, so
the row type is `Nil`. The function is named after the `SET` column (`day_rate`) for the
one scalar param Squirrel could attribute to a column.

A throwaway gleeunit test ran the generated function against the live PG19: seed L5 =
1200.00 for all of 2026, bump to 1400.00 for 2026-07-01..2027-01-01, then read back via
`lower()/upper()`. PG split the single row into exactly:
`(1200.00, 2026-01-01, 2026-07-01)` and `(1400.00, 2026-07-01, 2027-01-01)` — passed
(`10 passed, no failures`).

Notes for downstream tasks:
- `rate_card`'s `PRIMARY KEY (level, valid_at WITHOUT OVERLAPS)` requires the
  `btree_gist` extension (the scalar `level` needs a GiST opclass); without it the
  CREATE TABLE fails with *"data type integer has no default operator class for access
  method gist"*. The migrations (P2-T01) must `CREATE EXTENSION btree_gist`.
- `FOR PORTION OF` reports `UPDATE 1` even though two rows result — the unchanged
  carve-off period is an implicit insert. Don't rely on the affected-row count to detect
  a split.
- The generated module imports `gleam/time/calendar` (`gleam_time`, transitive via pog);
  expect a "transitive dependency imported" warning until `gleam_time` is a direct dep
  (handle in P0-T01).

All scratch artifacts removed (spike `.sql`, generated module, spike test, the
`rate_card` table); the DB is back to the `schema_migrations`-only state this task found.
