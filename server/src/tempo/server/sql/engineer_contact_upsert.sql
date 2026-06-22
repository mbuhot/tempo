-- engineer_contact_upsert.sql — record contact details from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new values + audit_id on the [$2, NULL) portion of the covering version,
-- and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
-- If no version covers $2 (the founding write at onboard) the Change touches nothing,
-- so the guarded INSERT opens the first [$2, NULL) span instead. $1 = engineer_id,
-- $2 = effective, $3 = name, $4 = email, $5 = phone, $6 = postal, $7 = audit_id.
WITH changed AS (
  UPDATE engineer_contact
     FOR PORTION OF recorded_during FROM $2::date TO NULL
     SET name = $3, email = $4, phone = $5, postal_address = $6, audit_id = $7
   WHERE engineer_id = $1
     AND recorded_during @> $2::date
  RETURNING 1
)
INSERT INTO engineer_contact
  (engineer_id, name, email, phone, postal_address, recorded_during, audit_id)
SELECT $1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7
WHERE NOT EXISTS (SELECT 1 FROM changed);
