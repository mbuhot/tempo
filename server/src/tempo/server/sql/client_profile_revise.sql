-- client_profile_revise.sql — record a new client profile from $2 onward (the Change
-- pattern). FOR PORTION OF sets the new name + audit_id on the [$2, NULL) portion; PG
-- carves off the unchanged [start, $2) remainder keeping its original audit_id.
-- $1 = client_id, $2 = effective, $3 = name, $4 = audit_id.
UPDATE client_profile
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET name = $3, audit_id = $4
 WHERE client_id = $1
   AND recorded_during @> $2::date;
