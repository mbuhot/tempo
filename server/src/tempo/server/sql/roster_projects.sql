-- roster_projects.sql — projects ACTIVE as-of the date ($1::date).
--
-- The project-directory slice the operations console offers as a name <select>:
-- only projects whose active window covers the slider's as-of date. The
-- `active_during` WITHOUT OVERLAPS constraint guarantees at most one row per
-- project id per date, so this returns one row per active project, id + name,
-- ordered by name for a stable, alphabetised dropdown.
SELECT id, name
FROM project
WHERE active_during @> $1::date
ORDER BY name;
