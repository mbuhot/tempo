-- schedule_lanes.sql — one row per allocated engineer x week for every project in
-- the window: the fraction in force at the week start and whether leave covers it.
-- Lane level is as-of $1 (the label), coalesced to 0 when no role row covers it.
-- $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
)
SELECT
  allocation.project_id,
  allocation.engineer_id,
  coalesce(engineer_current.name, '') AS name,
  coalesce(role_now.level, 0) AS level,
  weeks.week,
  allocation.fraction AS fraction,
  (leave.engineer_id IS NOT NULL) AS on_leave
FROM weeks
JOIN allocation ON allocation.allocated_during @> weeks.week
JOIN engineer_current ON engineer_current.id = allocation.engineer_id
LEFT JOIN engineer_role role_now
  ON role_now.engineer_id = allocation.engineer_id
 AND role_now.held_during @> $1::date
LEFT JOIN leave
  ON leave.engineer_id = allocation.engineer_id
 AND leave.on_leave_during @> weeks.week
ORDER BY allocation.project_id, name, weeks.week;
