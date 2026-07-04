-- schedule_level_gaps.sql — level requirement lines per project per week with the
-- covered sum (allocated fractions of engineers at level >= required, off leave).
-- Gap arithmetic happens in the view: gap = greatest(0, quantity - covered).
-- $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
)
SELECT
  requirement.project_id,
  requirement.level,
  weeks.week,
  requirement.quantity AS quantity,
  coalesce(
    sum(allocation.fraction)
      FILTER (WHERE role_week.level >= requirement.level
                AND leave.engineer_id IS NULL),
    0) AS covered
FROM weeks
JOIN project_requirement requirement ON requirement.required_during @> weeks.week
LEFT JOIN allocation
  ON allocation.project_id = requirement.project_id
 AND allocation.allocated_during @> weeks.week
LEFT JOIN engineer_role role_week
  ON role_week.engineer_id = allocation.engineer_id
 AND role_week.held_during @> weeks.week
LEFT JOIN leave
  ON leave.engineer_id = allocation.engineer_id
 AND leave.on_leave_during @> weeks.week
GROUP BY requirement.project_id, requirement.level, weeks.week, requirement.quantity
ORDER BY requirement.project_id, requirement.level, weeks.week;
