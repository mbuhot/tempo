-- project_profile_current.sql — a project's CURRENT profile (latest read).
--
-- The most-recently-effective project_profile row for one project: DISTINCT ON
-- ordered by the start of recorded_during descending. Append-only + WITHOUT
-- OVERLAPS means the row with the greatest start is the one whose [effective, NULL)
-- span is in force. Scalar columns only — recorded_during bounds are not exposed
-- (the read record is scalar-only). $1 = project_id.
SELECT DISTINCT ON (project_id)
  project_id,
  title,
  summary
FROM project_profile
WHERE project_id = $1
ORDER BY project_id, lower(recorded_during) DESC;
