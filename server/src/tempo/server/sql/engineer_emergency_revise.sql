-- engineer_emergency_revise.sql — record a new emergency contact from $2 onward (the
-- Change pattern). FOR PORTION OF sets the new values + audit_id on the [$2, NULL)
-- portion; PG carves off the unchanged [start, $2) remainder keeping its original
-- audit_id. $1 = engineer_id, $2 = effective, $3 = relation, $4 = name, $5 = phone,
-- $6 = email, $7 = audit_id.
UPDATE engineer_emergency
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET relation = $3, name = $4, phone = $5, email = $6, audit_id = $7
 WHERE engineer_id = $1
   AND recorded_during @> $2::date;
