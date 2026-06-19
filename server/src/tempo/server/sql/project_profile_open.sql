-- project_profile_open.sql — step 2 of the profile Change (and the row StartProject
-- writes).
--
-- Insert the new full profile row over [$4, NULL): daterange($4::date, NULL, '[)'),
-- so only scalar params cross the Squirrel boundary. Run after project_profile_close
-- has carved [$4, NULL) out of the covering row, so the WITHOUT OVERLAPS PK is
-- satisfied. $1 = project_id, $2 = title, $3 = summary, $4 = effective date.
INSERT INTO project_profile
  (project_id, title, summary, recorded_during)
VALUES ($1, $2, $3, daterange($4::date, NULL, '[)'));
