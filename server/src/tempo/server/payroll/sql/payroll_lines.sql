-- payroll_lines.sql — the persisted payroll lines for a period (GET /api/payroll).
-- Reads the SNAPSHOT lines a RunPayroll produced (payroll_line), joined to the
-- engineer name — not a recomputation (the read returns what was paid, the
-- write-time analogue of payroll_amounts).
--
-- Params: $1 = period start (date), $2 = period end (date, exclusive). The period
-- range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
-- Squirrel boundary. Lines for every run whose period OVERLAPS the window are
-- returned (the caller queries month-aligned windows, so in practice exactly the
-- one run for that month). Ordered by engineer name for a deterministic wire
-- order; an engineer with lines in two overlapping runs would appear twice (not
-- expected for month-aligned windows).
WITH params AS (
  SELECT daterange($1::date, $2::date, '[)') AS period
)
SELECT
  coalesce(engineer.name, '') AS engineer,
  payroll_line.amount::numeric AS amount,
  payroll_line.days::numeric AS days
FROM params
JOIN payroll_period ON payroll_period.period && params.period
JOIN payroll_line   ON payroll_line.run_id = payroll_period.run_id
JOIN engineer_current engineer ON engineer.id = payroll_line.engineer_id
ORDER BY engineer.name;
