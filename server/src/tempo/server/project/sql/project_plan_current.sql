-- project_plan_current.sql — a project's CURRENT plan (latest read).
--
-- The most-recently-effective project_plan row for one project: DISTINCT ON ordered
-- by the start of planned_during descending. Append-only + WITHOUT OVERLAPS means
-- the row with the greatest start is the one whose [effective, NULL) span is in
-- force. Scalar columns only — planned_during bounds are not exposed (the read
-- record is scalar-only). $1 = project_id.
SELECT DISTINCT ON (project_id)
  project_id,
  budget::text AS budget,
  target_completion
FROM project_plan
WHERE project_id = $1
ORDER BY project_id, lower(planned_during) DESC;
