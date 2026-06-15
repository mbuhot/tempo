-- timesheet_delete.sql — step 1 of the temporal upsert (P1-T04).
--
-- `ON CONFLICT` cannot target the WITHOUT OVERLAPS PK (it is a GiST exclusion
-- constraint, not a plain unique index), so re-entry is delete-then-insert run in
-- ONE transaction by the handler (see timesheet_write.sql). This removes whatever
-- row *covers* the day, using the same `@> $3::date` containment the PK enforces,
-- so it is correct regardless of the stored range's exact bounds.
--
-- First entry deletes 0 rows (a harmless no-op); re-entry deletes 1. Never branch
-- on the affected-row count. $1 = engineer_id, $2 = project_id, $3 = the day.
DELETE FROM timesheet
WHERE engineer_id = $1
  AND project_id  = $2
  AND work_day @> $3::date;
