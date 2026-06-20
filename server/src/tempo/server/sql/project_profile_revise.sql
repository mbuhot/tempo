-- project_profile_revise.sql — record a new project profile from $2 onward (the
-- Change pattern). FOR PORTION OF sets the new values + audit_id on the [$2, NULL)
-- portion; PG carves off the unchanged [start, $2) remainder keeping its original
-- audit_id. $1 = project_id, $2 = effective, $3 = title, $4 = summary, $5 = audit_id.
UPDATE project_profile
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET title = $3, summary = $4, audit_id = $5
 WHERE project_id = $1
   AND recorded_during @> $2::date;
