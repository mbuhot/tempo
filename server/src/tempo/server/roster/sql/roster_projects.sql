-- roster_projects.sql — projects ACTIVE as-of the date ($1::date).
--
-- The project-directory slice the operations console offers as a name <select>:
-- only projects whose active window covers the slider's as-of date. The run's
-- `active_during` WITHOUT OVERLAPS constraint guarantees at most one project_run
-- row per project id per date, so this returns one row per active project, id +
-- name, ordered by name for a stable, alphabetised dropdown. The NAME left the
-- project anchor for the project_profile fact, so the title is read through the
-- `project_current` view (latest profile per project) and coalesced to keep the
-- String contract past Squirrel's nullable-view inference.
SELECT project_run.project_id AS id, coalesce(project_current.title, '') AS name
FROM project_run
JOIN project_current ON project_current.id = project_run.project_id
WHERE project_run.active_during @> $1::date
ORDER BY name;
