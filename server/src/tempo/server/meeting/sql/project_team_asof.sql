-- project_team_asof.sql — the distinct engineers allocated to project $1 as-of
-- date $2 (the "Fill from project" affordance in the find-a-time wizard, per the
-- design doc's participant table). $1 = project_id, $2 = as-of date.
SELECT DISTINCT engineer_id
FROM allocation
WHERE project_id = $1 AND allocated_during @> $2::date
ORDER BY engineer_id;
