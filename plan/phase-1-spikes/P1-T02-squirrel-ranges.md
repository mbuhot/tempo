---
id: P1-T02
phase: 1
title: Spike — Squirrel daterange decomposition
status: done
depends_on: [P0-T01, P0-T03]
parallelizable_with: [P1-T01, P1-T03, P1-T04]
agent: workflow
---

# P1-T02 — Spike: Squirrel ↔ `daterange` decomposition

## Objective
Verify the range-decomposition boundary lets Squirrel generate clean typed code without depending on
`daterange`/`datemultirange` mapping.

## References
- `ARCHITECTURE.md` §6 (Squirrel integration), §11.2
- `DECISIONS.md` ADR-011

## Work
- [ ] Author a tiny `.sql` query that SELECTs `lower(valid_at) AS valid_from`,
      `upper(valid_at) AS valid_to` (plain `date`) from a temporal table.
- [ ] Author a write that accepts a range built in SQL: `daterange($from, $to, '[)')`.
- [ ] Run `gleam run -m squirrel`; confirm generated functions type `date` params/returns cleanly.
- [ ] Round-trip a value through generated code.

## Acceptance
- Generated code compiles and round-trips, confirming ADR-011, **or** document the needed adjustment.

## Finding

**ADR-011 confirmed.** The `lower()/upper()` decomposition lets Squirrel generate clean, fully-typed
Gleam without any `daterange`/`datemultirange` mapping. Verified against the running PG19 container
(`postgres:19beta1` — `PostgreSQL 19beta1 (Debian 19~beta1-1.pgdg13+1)`, host port 5434).

Method (throwaway, since cleaned up): created a temporal scratch table
`spike_employment(engineer_id int, valid_at daterange, PRIMARY KEY (engineer_id, valid_at WITHOUT OVERLAPS))`,
authored three scratch `.sql` queries, ran `gleam run -m squirrel`, and round-tripped a value
through the generated functions via a `gleam test`.

What Squirrel generated (PG19 introspection, squirrel v4.7.0):
- **Write** — `INSERT ... VALUES ($1, daterange($2, $3, '[)'))` typed as
  `spike_insert_employment(db, arg_1: Int, arg_2: Date, arg_3: Date)`. The range is built in SQL; the
  function only ever sees scalar `date` params (`pog.calendar_date`).
- **Read** — `SELECT lower(valid_at) AS valid_from, upper(valid_at) AS valid_to` produced a row type
  `SpikeSelectEmploymentRow(engineer_id: Int, valid_from: Date, valid_to: Date)` decoded with
  `pog.calendar_date_decoder()`. No `daterange` type appears anywhere in the generated module.
- `Date` is `gleam/time/calendar.Date(year, month, day)` (gleam_time package).

Round-trip: inserting `($from=2026-01-01, $to=2026-03-01)` stored `valid_at = [2026-01-01,2026-03-01)`
and the as-of select (`valid_at @> $1::date`) returned exactly `valid_from=2026-01-01`,
`valid_to=2026-03-01`. `gleam check` + `gleam test` green.

**Required adjustment (applied):** the generated code for `date` columns imports
`gleam/time/calendar`, which is only a *transitive* dependency (via pog). Squirrel/Gleam emits a
"Transitive dependency imported" warning (a hard compile error in a future Gleam). Resolved by
`gleam add gleam_time` — `gleam_time >= 1.8.0 and < 2.0.0` is now a direct dependency (the only
lasting change from this spike; gleam.toml + manifest.toml). All other artifacts (scratch `.sql`,
generated `sql.gleam`, scratch test, `spike_employment` table) were removed.

**Two incidental notes for downstream tasks (Phase 2 schema):**
- `WITHOUT OVERLAPS` on a PK that includes an `int` column (e.g. `engineer_id`) needs the
  `btree_gist` extension, otherwise: `ERROR: data type integer has no default operator class for
  access method "gist"`. The init migration must `CREATE EXTENSION IF NOT EXISTS btree_gist;` before
  the temporal tables. (Left enabled on the dev DB since it is required anyway.)
- Squirrel only discovers `*.sql` files in a directory literally named `sql` under `src`/`test`/`dev`
  — confirms the `src/tempo/server/sql/` location in ARCHITECTURE.md §6.
- Squirrel reads `DATABASE_URL` (or libpq `PG*` vars); the codegen invocation must point at the
  PG19 container, e.g. `DATABASE_URL="postgres://tempo:tempo@127.0.0.1:5434/tempo" gleam run -m squirrel`.
