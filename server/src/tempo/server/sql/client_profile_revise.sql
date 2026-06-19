-- client_profile_revise.sql — record a new client profile from $2 onward in ONE
-- statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
-- value on the [$2, NULL) portion of the row covering $2; PG carves off the
-- unchanged [start, $2) remainder as its own row. The `@>` guard confines it to the
-- single covering row. $1 = client_id, $2 = effective date, $3 = name.
UPDATE client_profile
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET name = $3
 WHERE client_id = $1
   AND recorded_during @> $2::date;
