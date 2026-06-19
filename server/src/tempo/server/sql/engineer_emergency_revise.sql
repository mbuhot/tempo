-- engineer_emergency_revise.sql — record a new emergency contact from $2 onward in
-- ONE statement (the Change pattern, like salary_revise). FOR PORTION OF sets the
-- new values on the [$2, NULL) portion of the row covering $2; PG carves off the
-- unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
-- $1 = engineer_id, $2 = effective, $3 = relation, $4 = name, $5 = phone, $6 = email.
UPDATE engineer_emergency
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET relation = $3, name = $4, phone = $5, email = $6
 WHERE engineer_id = $1
   AND recorded_during @> $2::date;
