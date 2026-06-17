-- payroll_amounts.sql — the prorated salary owed per employed engineer for a month
-- (FR-F5, FR-F6). One row per engineer employed at any point in the month.
--
-- Params: $1 = month start (date), $2 = month end (date, exclusive). The month
-- range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
-- Squirrel boundary.
--
-- Proration by day, split by level (FR-F6). The paid period is the intersection
-- (the * operator) of employment, the engineer_role (level) version, the salary
-- version, and the month. Splitting on BOTH the role version and the salary
-- version means a mid-month promotion is paid partly at each level's salary, and a
-- mid-month salary revision is honoured day-accurate within a level. A daterange's
-- day count is upper - lower (integer days; e.g. 30 for June). Days in the month
-- is likewise upper(month) - lower(month) (28..31), so the divisor is the actual
-- calendar length of the billed month.
--
--   amount = Σ over sub-periods of  monthly_salary[level] × days_in_subperiod
--                                                          / days_in_month
--   days   = Σ over sub-periods of  days_in_subperiod   (the employed days in month)
--
-- Leave is IGNORED — full pay (FR-F6). The leave table is not consulted: a leave
-- period is paid at full salary, so payroll prorates only over employment, not over
-- "employment minus leave". A hire or termination mid-month clips the paid period
-- to the employed days (employment ∩ month); a promotion splits it.
--
-- Assumptions:
--   * salary has a version covering every (level, day) an engineer is employed in
--     the month (true in the seed: the baseline salary opens at the earliest
--     employment date). An employed day with no salary version yields no
--     sub-period and is silently unpaid — a seed/data gap, not a modelled state.
--   * engineer_role spans employment (every employed engineer has a level), so
--     every employed day is attributed to exactly one level via the intersection.
--   * Calendar days, not business days; full-month salary = monthly_salary when the
--     engineer is employed the whole month at one level.
WITH params AS (
  SELECT daterange($1::date, $2::date, '[)') AS month
),
sub AS (
  -- each employment ∩ engineer_role(level) ∩ salary-version ∩ month sub-period
  SELECT
    employment.engineer_id,
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
  engineer.name AS engineer,
  sum(sub.monthly_salary * (upper(sub.sub_period) - lower(sub.sub_period))
      / (upper(params.month) - lower(params.month)))::numeric AS amount,
  sum(upper(sub.sub_period) - lower(sub.sub_period))::numeric AS days
FROM sub
CROSS JOIN params
JOIN engineer ON engineer.id = sub.engineer_id
WHERE NOT isempty(sub.sub_period)
GROUP BY sub.engineer_id, engineer.name
ORDER BY engineer.name;
