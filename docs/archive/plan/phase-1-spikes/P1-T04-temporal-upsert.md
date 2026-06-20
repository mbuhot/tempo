---
id: P1-T04
phase: 1
title: Spike — Temporal upsert for timesheet
status: done
depends_on: [P0-T03]
parallelizable_with: [P1-T01, P1-T02, P1-T03]
agent: workflow
---

# P1-T04 — Spike: Temporal upsert for timesheet

## Objective
Determine the re-entry (upsert) approach for `timesheet`, whose `WITHOUT OVERLAPS` PK is an
exclusion constraint that `ON CONFLICT` cannot target.

## References
- `ARCHITECTURE.md` §5 (impl note on upsert), §11.4

## Work
- [ ] Confirm `INSERT … ON CONFLICT` fails / is unsupported against the `WITHOUT OVERLAPS` PK.
- [ ] Validate the chosen fallback: delete-then-insert within a transaction
      (`DELETE … WHERE work_day @> $day; INSERT …`), or a supplemental unique index for the upsert
      path.
- [ ] Pick one and note it for P3-T05 (timesheet write).

## Acceptance
- A working, documented re-entry approach for a single `(engineer, project, day)` timesheet row.

## Finding

**Decision: delete-then-insert within a transaction.** Adopt this for P3-T05 (timesheet write).

Verified against Docker `postgres:19beta1` (PG 19beta1 on aarch64; the running shared
`tempo-db` container, port 5434, db/user `tempo`). Ran a minimal slice of the §4 schema
(engineer / employment / project / allocation / timesheet, all single-day `[d, d+1)` `work_day`)
in a throwaway scratch database, now dropped. `WITHOUT OVERLAPS` PKs required
`CREATE EXTENSION btree_gist` (needed for the GiST opclass on the scalar key columns).

`ON CONFLICT` confirmed unusable against the `WITHOUT OVERLAPS` PK:
- `ON CONFLICT (engineer_id, project_id, work_day) DO UPDATE` →
  `ERROR: there is no unique or exclusion constraint matching the ON CONFLICT specification`
  (column inference cannot match an exclusion-backed PK).
- `ON CONFLICT ON CONSTRAINT timesheet_pkey DO UPDATE` →
  `ERROR: ON CONFLICT DO UPDATE not supported with exclusion constraints`.
- Bare `ON CONFLICT DO NOTHING` is *accepted* but is not an upsert — it silently drops the
  re-entry's new hours, so it cannot serve the form's "edit and resubmit" path.

Delete-then-insert (recommended) — one code path for both first entry and re-entry:
```sql
BEGIN;
DELETE FROM timesheet
 WHERE engineer_id = $1 AND project_id = $2 AND work_day @> $3::date;
INSERT INTO timesheet (engineer_id, project_id, work_day, hours)
VALUES ($1, $2, daterange($3::date, ($3::date + 1), '[)'), $4);
COMMIT;
```
- Re-entry: `DELETE 1` then `INSERT 1` — hours replaced, exactly one row remains.
- First entry: `DELETE 0` (no-op) then `INSERT 1` — same statements, no special-casing.
- The `work_day @> $3::date` containment predicate deletes whatever row *covers* the day
  regardless of its exact range bounds, matching the PK's overlap semantics exactly.
- The PERIOD FK to `allocation` is still enforced: logging a day with no covering allocation
  is rejected and the whole transaction rolls back atomically (FR-5 preserved). The two
  statements MUST run in one transaction so a rejected INSERT does not leave the prior row deleted.

Supplemental UNIQUE index (rejected alternative) — `CREATE UNIQUE INDEX … (engineer_id,
project_id, work_day)` is a plain btree (not GiST) and *can* back `ON CONFLICT … DO UPDATE`.
It works for canonical single-day writes only because `daterange` normalizes every single-day
literal (including `[]`-bounded input) to the identical `[d, d+1)` value, so btree equality
matches. Rejected because: (1) it keys on range *equality* while the PK enforces *overlap*, so a
multi-day `work_day` that contains the same day is a different index key — `ON CONFLICT` cannot
infer it, the INSERT proceeds, and the PK exclusion constraint then throws a raw
`conflicting key value violates exclusion constraint` (verified); (2) it adds a second index to
maintain that duplicates the PK for the narrow single-day case. The delete-then-insert path needs
no extra index and is robust to range bounds.
