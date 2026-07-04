-- schedule_weeks.sql — the 12 week-start Mondays opening at the Monday of $1.
-- $1 = as_of.
SELECT week_start::date AS week
FROM generate_series(
  date_trunc('week', $1::date),
  date_trunc('week', $1::date) + interval '11 weeks',
  interval '1 week') AS week_start
ORDER BY week;
