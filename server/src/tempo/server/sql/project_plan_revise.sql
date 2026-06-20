-- project_plan_revise.sql — record a new project plan from $2 onward (the Change
-- pattern). FOR PORTION OF sets the new values + audit_id on the [$2, NULL) portion;
-- PG carves off the unchanged [start, $2) remainder keeping its original audit_id.
-- $1 = project_id, $2 = effective, $3 = budget, $4 = target_completion, $5 = audit_id.
UPDATE project_plan
   FOR PORTION OF planned_during FROM $2::date TO NULL
   SET budget = $3, target_completion = $4::date, audit_id = $5
 WHERE project_id = $1
   AND planned_during @> $2::date;
