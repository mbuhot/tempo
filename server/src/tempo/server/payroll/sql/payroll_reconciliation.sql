-- payroll_reconciliation.sql — the month's payroll panel: the LIVE recompute over
-- current facts side by side with the MATERIALIZED payroll_line frozen at run time
-- (FR-F5/FR-F6). One row per engineer present on EITHER side, so an employed
-- engineer not yet in the run (preview only) and an engineer in the run but no
-- longer employed (paid only) both surface.
--
-- Params: $1 = month start (date), $2 = month end (date, exclusive). The month
-- range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
-- Squirrel boundary.
--
-- The LIVE side (preview_amount/preview_days) reuses payroll_amounts' proration
-- CTE verbatim: each employment ∩ engineer_role(level) ∩ salary-version ∩ month
-- sub-period, summed at monthly_salary × days_in_subperiod / days_in_month. A
-- back-dated promotion or salary revision shifts these slices, so the preview is
-- "what should be paid now".
--
-- The PAID side (paid_amount/paid_days) reads the payroll_line a RunPayroll wrote,
-- via the run whose period OVERLAPS the month (payroll_period.period && month). It
-- is NULL until a run exists, and frozen once written, so it does NOT move when a
-- fact is back-dated. The variance preview − paid is the back-pay the correction
-- owes — the bitemporal payoff.
--
-- run_id (nullable) is the run for the month, carried on every row so the caller
-- knows whether a materialized run exists without a second query. FULL OUTER JOIN
-- on engineer_id unions the two sides; ordered by engineer name.
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
),
preview AS (
  SELECT
    sub.engineer_id,
    sum(prorated_salary(sub.monthly_salary, sub.sub_period, params.month))::numeric
      AS amount,
    sum(range_days(sub.sub_period))::numeric AS days
  FROM sub
  CROSS JOIN params
  WHERE NOT isempty(sub.sub_period)
  GROUP BY sub.engineer_id
),
run AS (
  SELECT payroll_period.run_id
  FROM params
  JOIN payroll_period ON payroll_period.period && params.month
),
paid AS (
  SELECT
    payroll_line.engineer_id,
    payroll_line.amount::numeric AS amount,
    payroll_line.days::numeric AS days
  FROM payroll_line
  JOIN run ON run.run_id = payroll_line.run_id
)
SELECT
  (SELECT run_id FROM run) AS "run_id?",
  coalesce(engineer.name, '') AS engineer,
  coalesce(preview.amount, 0)::numeric AS preview_amount,
  coalesce(preview.days, 0)::numeric AS preview_days,
  paid.amount AS "paid_amount?",
  paid.days AS "paid_days?"
FROM preview
FULL OUTER JOIN paid ON paid.engineer_id = preview.engineer_id
JOIN engineer_current engineer
  ON engineer.id = coalesce(preview.engineer_id, paid.engineer_id)
ORDER BY engineer.name;
