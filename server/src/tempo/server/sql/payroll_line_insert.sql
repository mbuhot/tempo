-- payroll_line_insert.sql — append one engineer's line to a payroll run.
--
-- A plain INSERT (write pattern 1). The amount and days are pre-computed by the
-- command from salary and the engineer's worked/employed days in the run period.
-- $1 = run_id, $2 = engineer_id, $3 = amount, $4 = days.
INSERT INTO payroll_line (run_id, engineer_id, amount, days)
VALUES ($1, $2, $3, $4);
