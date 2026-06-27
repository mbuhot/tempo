-- payroll_segments.sql — the per-level breakdown of each engineer's prorated salary
-- for a month (#23): one row per (engineer, level, salary) sub-period, the detail
-- payroll_amounts sums away. Used to FREEZE a run's breakdown (payroll_line_segment)
-- and as the LIVE preview breakdown the Payroll panel discloses.
--
-- Params: $1 = month start (date), $2 = month end (date, exclusive).
--
-- The sub CTE is payroll_amounts' proration verbatim — employment ∩ engineer_role
-- (level) ∩ salary-version ∩ month — but carrying the level, and grouped by
-- (engineer, level, monthly_salary) rather than summed to one line. A mid-month
-- promotion yields one row per level; a mid-month salary revision within a level
-- yields one row per salary. The segments of an engineer sum back to their
-- payroll_amounts total (same kernels), so total ≡ Σ segments.
WITH params AS (
  SELECT daterange($1::date, $2::date, '[)') AS month
),
sub AS (
  SELECT
    employment.engineer_id,
    engineer_role.level,
    salary.monthly_salary,
    employment.employed_during
      * engineer_role.held_during
      * salary.effective_during
      * params.month AS sub_period
  FROM params
  JOIN employment    ON employment.employed_during && params.month
  JOIN engineer_role ON engineer_role.engineer_id = employment.engineer_id
                    AND engineer_role.held_during && employment.employed_during
                    AND engineer_role.held_during && params.month
  JOIN salary        ON salary.level = engineer_role.level
                    AND salary.effective_during && engineer_role.held_during
                    AND salary.effective_during && params.month
)
SELECT
  sub.engineer_id,
  sub.level,
  sub.monthly_salary::text AS monthly_salary,
  sum(range_days(sub.sub_period))::numeric AS days,
  sum(prorated_salary(sub.monthly_salary, sub.sub_period, params.month))::text
    AS amount
FROM sub
CROSS JOIN params
WHERE NOT isempty(sub.sub_period)
GROUP BY sub.engineer_id, sub.level, sub.monthly_salary
ORDER BY sub.engineer_id, sub.level;
