-- engineer_emergency_upsert.sql — record an emergency contact from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new values + audit_id on the [$2, NULL) portion of the covering version,
-- and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
-- If no version covers $2 (the founding write) the Change touches nothing, so the
-- guarded INSERT opens the first [$2, NULL) span instead. $1 = engineer_id,
-- $2 = effective, $3 = relation, $4 = name, $5 = phone, $6 = email, $7 = audit_id.
WITH changed AS (
  UPDATE engineer_emergency
     FOR PORTION OF recorded_during FROM $2::date TO NULL
     SET relation = $3, name = $4, phone = $5, email = $6, audit_id = $7
   WHERE engineer_id = $1
     AND recorded_during @> $2::date
  RETURNING 1
)
INSERT INTO engineer_emergency
  (engineer_id, relation, name, phone, email, recorded_during, audit_id)
SELECT $1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7
WHERE NOT EXISTS (SELECT 1 FROM changed);
