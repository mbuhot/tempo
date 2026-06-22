-- project_plan_upsert.sql — record a project plan from $2 onward in one statement (the
-- temporal upsert). The writable CTE runs the Change: FOR PORTION OF sets the new
-- values + audit_id on the [$2, NULL) portion of the covering version, and PG carves
-- off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id. If no version
-- covers $2 (the founding write at start_project) the Change touches nothing, so the
-- guarded INSERT opens the first [$2, NULL) span instead. $1 = project_id,
-- $2 = effective, $3 = budget, $4 = target_completion, $5 = audit_id.
WITH changed AS (
  UPDATE project_plan
     FOR PORTION OF planned_during FROM $2::date TO NULL
     SET budget = $3, target_completion = $4::date, audit_id = $5
   WHERE project_id = $1
     AND planned_during @> $2::date
  RETURNING 1
)
INSERT INTO project_plan
  (project_id, budget, target_completion, planned_during, audit_id)
SELECT $1, $3, $4::date, daterange($2::date, NULL, '[)'), $5
WHERE NOT EXISTS (SELECT 1 FROM changed);
