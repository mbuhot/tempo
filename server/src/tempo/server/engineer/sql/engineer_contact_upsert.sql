-- engineer_contact_upsert.sql — record contact details from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
-- as the upper bound asserts the new details hold to infinity, superseding any scheduled
-- future versions. $1 = engineer_id, $2 = effective, $3 = name, $4 = email, $5 = phone,
-- $6 = postal, $7 = audit_id.
WITH deleted AS (
  DELETE FROM engineer_contact
     FOR PORTION OF recorded_during FROM $2::date TO NULL
   WHERE engineer_id = $1
)
INSERT INTO engineer_contact
  (engineer_id, name, email, phone, postal_address, recorded_during, audit_id)
VALUES ($1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7);
