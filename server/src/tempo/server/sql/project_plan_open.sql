-- project_plan_open.sql — step 2 of the plan Change (and the row StartProject
-- writes).
--
-- Insert the new full plan row over [$4, NULL): daterange($4::date, NULL, '[)'), so
-- only scalar params cross the Squirrel boundary. Run after project_plan_close has
-- carved [$4, NULL) out of the covering row, so the WITHOUT OVERLAPS PK is
-- satisfied. $1 = project_id, $2 = budget, $3 = target_completion date, $4 =
-- effective date.
INSERT INTO project_plan
  (project_id, budget, target_completion, planned_during)
VALUES ($1, $2, $3::date, daterange($4::date, NULL, '[)'));
