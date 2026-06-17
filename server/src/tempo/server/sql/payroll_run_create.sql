-- payroll_run_create.sql — open a payroll run for a period.
--
-- A plain INSERT (write pattern 1). The id is auto-generated and returned. The
-- period is a daterange built from the half-open [$1, $2) month bounds.
INSERT INTO payroll_run (period)
VALUES (daterange($1::date, $2::date, '[)'))
RETURNING id;
