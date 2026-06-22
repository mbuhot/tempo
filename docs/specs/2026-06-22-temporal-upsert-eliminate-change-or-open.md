# Temporal Upsert — eliminate the `change_or_open` pattern

**Status:** Approved (design). Implementation to follow; ADR-045 to be added to
`docs/DECISIONS.md` during the build.

## Problem

Every open-ended versioned attribute is written today as a two-step `change_or_open`
in `repository.gleam`: run the `FOR PORTION OF` **change**, inspect its row count, and
if it touched **0** rows (no version yet covers `from` — the founding write at
onboard / start_project) fall back to an **open** INSERT. This forces every such
attribute to carry a *pair* of `.sql` files (`*_revise`/`*_change` + `*_open`) and a
helper (`change_or_open`) whose only job is to branch on the count. The same logical
write — "record this attribute from `from` onward" — is split across two statements,
two files, and a round-trip-plus-conditional in Gleam.

Seven attributes use the pattern:

| Fact | Table | Period column | Value columns | Containment FK |
|------|-------|---------------|---------------|----------------|
| `EngineerAtLevel` | `engineer_role` | `held_during` | `level` | `engineer_role_within_employment` |
| `EngineerContactDetails` | `engineer_contact` | `recorded_during` | `name, email, phone, postal_address` | — |
| `EngineerBankingDetails` | `engineer_banking` | `recorded_during` | `bank, branch, account_no, account_name` | — |
| `EngineerEmergencyContact` | `engineer_emergency` | `recorded_during` | `relation, name, phone, email` | — |
| `ProjectProfile` | `project_profile` | `recorded_during` | `title, summary` | — |
| `ProjectPlan` | `project_plan` | `planned_during` | `budget, target_completion` | — |
| `ClientProfile` | `client_profile` | `recorded_during` | `name` | — |

All 14 generated functions (`*_open` + `*_revise`/`*_change`) are called **only** from
inside `change_or_open`; nothing else references them (verified across `server/src` and
`server/test`; `002_seed.sql` and `constraint_test.gleam` write raw SQL, not these
functions).

## Approach

Collapse each pair into a **single writable-CTE temporal upsert** — one statement that
does the change, and inserts the founding span only when the change matched nothing:

```sql
WITH changed AS (
  UPDATE engineer_contact
     FOR PORTION OF recorded_during FROM $2::date TO NULL
     SET name = $3, email = $4, phone = $5, postal_address = $6, audit_id = $7
   WHERE engineer_id = $1 AND recorded_during @> $2::date
  RETURNING 1
)
INSERT INTO engineer_contact
  (engineer_id, name, email, phone, postal_address, recorded_during, audit_id)
SELECT $1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7
WHERE NOT EXISTS (SELECT 1 FROM changed);
```

- **Change branch** — a version covers `from`: the `UPDATE … FOR PORTION OF` sets the
  new values + `audit_id` on the `[from, NULL)` portion and PG re-inserts the
  `[start, from)` leftover at the OLD values **and its original `audit_id`**; the CTE
  returns a row, so the `NOT EXISTS` guard suppresses the INSERT.
- **Open branch** — nothing covers `from` (founding write): the UPDATE matches 0 rows,
  `changed` is empty, the INSERT opens the first `[from, NULL)` span.

This is the canonical upsert-via-writable-CTE: all sub-statements share one snapshot,
and the INSERT keys off the CTE's output (not the live table), so the branch is decided
inside the single statement with no read-back and no Gleam-side conditional.

**Validated against PG19 (`postgres:19beta1`, the running `tempo-db`)** on a throwaway
temp table with a `WITHOUT OVERLAPS` PK: first upsert (no covering version) → `INSERT 0
1`, one open row; second upsert (now covered) → `INSERT 0 0`, the `FOR PORTION OF`
carved `[2026-01-01, 2026-03-01)` keeping `audit_id = 10` while `[2026-03-01, NULL)`
took the new value + `audit_id = 20`. Both branches and the per-version provenance copy
work exactly as the current two-step does.

## Changes

**SQL files** (`server/src/tempo/server/sql/`):
- **Add** 7 `*_upsert.sql`: `engineer_role_upsert`, `engineer_contact_upsert`,
  `engineer_banking_upsert`, `engineer_emergency_upsert`, `project_profile_upsert`,
  `project_plan_upsert`, `client_profile_upsert`.
- **Delete** the 14 superseded files (`*_open` + `*_revise`/`*_change` for those seven
  attributes).
- **Canonical parameter order** for every upsert: `$1` anchor id, `$2` `from` (`::date`),
  then the value columns in table order, then `audit_id` last. (Matches the existing
  `*_revise` order; the `*_open` files put `from` before `audit_id` — the upsert
  standardises on the revise order.)
- Keep each file's header comment terse, in the house style (purpose + param legend),
  noting the change-or-open branch lives in the one statement.

**Codegen:** regenerate `server/src/tempo/server/sql.gleam` via `bin/squirrel` (needs the
live PG19 DB). Squirrel infers each param's type from its column usage; `$1..$n` are
deduped by number across the CTE.

**Repository** (`server/src/tempo/server/repository.gleam`):
- Replace each of the 7 `change_or_open(...)` call sites in `write/3` with a single
  `sql.<attr>_upsert(conn, …) |> operation.run`.
- **Delete** the `change_or_open/2` helper.
- Update the module doc comment (lines ~9–14) so it no longer describes the
  change-or-open fallback; it now says these attributes are a temporal upsert (one
  statement: change the covering version, else open the first span).

**No schema migration.** Same tables, constraints, and columns — this is purely a change
in how the writes are expressed. Error classification is unchanged: each upsert is run
through `operation.run`, so a CHECK / PERIOD-FK / overlap rejection (e.g.
`engineer_role_within_employment` on the founding role INSERT) still classifies into the
same typed `OperationError` by constraint name.

## Testing

- `operations_test.gleam` exercises these writes end-to-end through `command.dispatch` →
  `repository`, covering both the founding write and a later edit; it is the behavioural
  guard and must stay green unchanged.
- If any existing test asserts on a now-deleted `sql.*` function name it is updated to the
  upsert call; the grep shows none do.
- A focused assertion (extend `operations_test` if not already covered): for one
  attribute, after an open then a dated edit, the `[start, from)` leftover retains its
  original `audit_id` and the `[from, NULL)` portion carries the new one — the
  provenance-preservation property proven in the PG19 spike.
- Run `bin/test` (server suite) after regen; `bin/reseed` is not required (no schema
  change) but the suite's own setup applies.

## Out of scope / non-goals

- The other write shapes stay as they are: `record_hours` (delete-then-insert),
  `record_requirement` (clear-then-set), `record_departure` (cascading caps),
  rate/allocation/invoice-status writes. This change is only the `change_or_open` seven.
- No change to read paths, views, codecs, or the command/handler layer.

## Risks

- **Squirrel type inference on the CTE.** A param used in both the UPDATE and the INSERT
  SELECT must infer one consistent type. Low risk (the casts and column types already
  pin them), but the regen is the verification — if squirrel mis-infers or rejects the
  CTE, fall back to retaining the param casts explicitly. Caught immediately by `bin/squirrel`.
- **PG19 beta.** The writable-CTE + `FOR PORTION OF` combination is already validated on
  the pinned `19beta1` image (above); the prod target is the same image.

## Documentation

- Add **ADR-045** to `docs/DECISIONS.md`: temporal attributes are written as a
  single-statement writable-CTE upsert (supersedes the `change_or_open` two-step);
  rationale (one fact = one statement = one file; provenance copy preserved; validated on
  PG19), and the explicit non-goal that delete-then-insert / clear-then-set writes are
  unaffected.
- Update the `repository.gleam` module doc as noted above.
