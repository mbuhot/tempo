-- project_plan_revise.sql — record a new project plan from $2 onward in ONE
-- statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
-- values on the [$2, NULL) portion of the row covering $2; PG carves off the
-- unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
-- $1 = project_id, $2 = effective, $3 = budget, $4 = target_completion.
UPDATE project_plan
   FOR PORTION OF planned_during FROM $2::date TO NULL
   SET budget = $3, target_completion = $4::date
 WHERE project_id = $1
   AND planned_during @> $2::date;
