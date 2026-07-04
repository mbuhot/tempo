-- engineer_role_upsert.sql — record an engineer's level from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts a new row bounded by employment's upper end.
-- This supersedes any scheduled future roles within employment while respecting the
-- engineer_role_within_employment PERIOD FK. $1 = engineer_id, $2 = effective,
-- $3 = level, $4 = audit_id.
--
-- With no employment row covering $2 the INSERT ... SELECT matches nothing and
-- RETURNING yields zero rows; the repository rejects that (NoSuchVersion) rather
-- than journalling a silent no-op.
WITH deleted AS (
  DELETE FROM engineer_role
     FOR PORTION OF held_during FROM $2::date TO NULL
   WHERE engineer_id = $1
)
INSERT INTO engineer_role (engineer_id, level, held_during, audit_id)
SELECT $1, $3, daterange($2::date, upper(employed_during), '[)'), $4
FROM employment
WHERE engineer_id = $1
  AND employed_during @> $2::date
RETURNING 1 AS revised;
