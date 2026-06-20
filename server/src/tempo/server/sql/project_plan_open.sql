-- project_plan_open.sql — open a project's founding plan (budget/target). Last param
-- is the audit_id. $1 = project_id, $2 = budget, $3 = target_completion, $4 = from.
INSERT INTO project_plan
  (project_id, budget, target_completion, planned_during, audit_id)
VALUES ($1, $2, $3::date, daterange($4::date, NULL, '[)'), $5);
