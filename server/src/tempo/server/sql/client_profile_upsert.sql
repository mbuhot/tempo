-- client_profile_upsert.sql — record a client profile (the NAME) from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new name + audit_id on the [$2, NULL) portion of the covering version, and
-- PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id. If
-- no version covers $2 (the founding write) the Change touches nothing, so the guarded
-- INSERT opens the first [$2, NULL) span instead. $1 = client_id, $2 = effective,
-- $3 = name, $4 = audit_id.
WITH changed AS (
  UPDATE client_profile
     FOR PORTION OF recorded_during FROM $2::date TO NULL
     SET name = $3, audit_id = $4
   WHERE client_id = $1
     AND recorded_during @> $2::date
  RETURNING 1
)
INSERT INTO client_profile
  (client_id, name, recorded_during, audit_id)
SELECT $1, $3, daterange($2::date, NULL, '[)'), $4
WHERE NOT EXISTS (SELECT 1 FROM changed);
