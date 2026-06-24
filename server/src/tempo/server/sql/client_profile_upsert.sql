-- client_profile_upsert.sql — record a client profile from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts [$2, NULL) with the new name. Passing NULL
-- as the upper bound asserts the new name holds to infinity, superseding any scheduled
-- future versions. $1 = client_id, $2 = effective, $3 = name, $4 = audit_id.
WITH deleted AS (
  DELETE FROM client_profile
     FOR PORTION OF recorded_during FROM $2::date TO NULL
   WHERE client_id = $1
)
INSERT INTO client_profile
  (client_id, name, recorded_during, audit_id)
VALUES ($1, $3, daterange($2::date, NULL, '[)'), $4);
