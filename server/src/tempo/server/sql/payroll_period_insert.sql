-- payroll_period_insert.sql — the immutable 1:1 payroll period (one run per month).
-- Last param is the audit_id. $1 = run_id, $2 = from, $3 = to.
INSERT INTO payroll_period (run_id, period, audit_id)
VALUES ($1, daterange($2::date, $3::date, '[)'), $4);
