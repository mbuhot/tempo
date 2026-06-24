-- project_profile_upsert.sql — record a project profile from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
-- as the upper bound asserts the new profile holds to infinity, superseding any scheduled
-- future versions. $1 = project_id, $2 = effective, $3 = title, $4 = summary, $5 = audit_id.
WITH deleted AS (
  DELETE FROM project_profile
     FOR PORTION OF recorded_during FROM $2::date TO NULL
   WHERE project_id = $1
)
INSERT INTO project_profile
  (project_id, title, summary, recorded_during, audit_id)
VALUES ($1, $3, $4, daterange($2::date, NULL, '[)'), $5);
