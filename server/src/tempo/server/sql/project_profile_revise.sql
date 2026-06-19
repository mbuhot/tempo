-- project_profile_revise.sql — record a new project profile from $2 onward in ONE
-- statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
-- values on the [$2, NULL) portion of the row covering $2; PG carves off the
-- unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
-- $1 = project_id, $2 = effective, $3 = title, $4 = summary.
UPDATE project_profile
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET title = $3, summary = $4
 WHERE project_id = $1
   AND recorded_during @> $2::date;
