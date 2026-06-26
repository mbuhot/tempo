-- project_plan_upsert.sql — record a project plan from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
-- as the upper bound asserts the new plan holds to infinity, superseding any scheduled
-- future versions. $1 = project_id, $2 = effective, $3 = budget (exact decimal
-- text, cast to numeric), $4 = target_completion, $5 = audit_id.
WITH deleted AS (
  DELETE FROM project_plan
     FOR PORTION OF planned_during FROM $2::date TO NULL
   WHERE project_id = $1
)
INSERT INTO project_plan
  (project_id, budget, target_completion, planned_during, audit_id)
VALUES ($1, $3::text::numeric, $4::date, daterange($2::date, NULL, '[)'), $5);
