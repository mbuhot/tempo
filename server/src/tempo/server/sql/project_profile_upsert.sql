-- project_profile_upsert.sql — record a project profile from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new values + audit_id on the [$2, NULL) portion of the covering version,
-- and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
-- If no version covers $2 (the founding write at start_project) the Change touches
-- nothing, so the guarded INSERT opens the first [$2, NULL) span instead.
-- $1 = project_id, $2 = effective, $3 = title, $4 = summary, $5 = audit_id.
WITH changed AS (
  UPDATE project_profile
     FOR PORTION OF recorded_during FROM $2::date TO NULL
     SET title = $3, summary = $4, audit_id = $5
   WHERE project_id = $1
     AND recorded_during @> $2::date
  RETURNING 1
)
INSERT INTO project_profile
  (project_id, title, summary, recorded_during, audit_id)
SELECT $1, $3, $4, daterange($2::date, NULL, '[)'), $5
WHERE NOT EXISTS (SELECT 1 FROM changed);
