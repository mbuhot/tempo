-- schedule_totals.sql — each engineer's total allocated fraction per week across
-- ALL projects, for the over-allocation flag (> 1.0). $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
)
SELECT allocation.engineer_id, weeks.week, sum(allocation.fraction) AS total
FROM weeks
JOIN allocation ON allocation.allocated_during @> weeks.week
GROUP BY allocation.engineer_id, weeks.week
ORDER BY allocation.engineer_id, weeks.week;
