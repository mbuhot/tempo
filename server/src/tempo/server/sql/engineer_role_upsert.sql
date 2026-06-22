-- engineer_role_upsert.sql — record an engineer's level from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new level + audit_id on the [$2, NULL) portion of the role in effect, and
-- PG re-inserts the [start, $2) leftover at the OLD level AND its original audit_id. If
-- no role covers $2 (the founding write at onboard) the Change touches nothing, so the
-- guarded INSERT opens the first [$2, NULL) span — contained by employment via the
-- engineer_role_within_employment PERIOD FK. $1 = engineer_id, $2 = effective,
-- $3 = level, $4 = audit_id.
WITH changed AS (
  UPDATE engineer_role
     FOR PORTION OF held_during FROM $2::date TO NULL
     SET level = $3, audit_id = $4
   WHERE engineer_id = $1
     AND held_during @> $2::date
  RETURNING 1
)
INSERT INTO engineer_role (engineer_id, level, held_during, audit_id)
SELECT $1, $3, daterange($2::date, NULL, '[)'), $4
WHERE NOT EXISTS (SELECT 1 FROM changed);
