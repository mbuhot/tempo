-- payroll_paid_segments.sql — the FROZEN per-level breakdown a RunPayroll persisted
-- (#23), for the Payroll panel's paid side. Reads payroll_line_segment via the run
-- whose period OVERLAPS the month — the snapshot analogue of payroll_segments, so a
-- completed run shows exactly the pro-rated days and salary it paid at each level,
-- unmoved by any later back-dated fact.
--
-- Params: $1 = month start (date), $2 = month end (date, exclusive). Empty until a
-- run exists. Ordered by engineer then level for a deterministic wire order.
WITH params AS (
  SELECT daterange($1::date, $2::date, '[)') AS period
),
run AS (
  SELECT payroll_period.run_id
  FROM params
  JOIN payroll_period ON payroll_period.period && params.period
)
SELECT
  payroll_line_segment.engineer_id,
  payroll_line_segment.level,
  payroll_line_segment.monthly_salary::text AS monthly_salary,
  payroll_line_segment.days::numeric AS days,
  payroll_line_segment.amount::text AS amount
FROM payroll_line_segment
JOIN run ON run.run_id = payroll_line_segment.run_id
ORDER BY payroll_line_segment.engineer_id, payroll_line_segment.level;
