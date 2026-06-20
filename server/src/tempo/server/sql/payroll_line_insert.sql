-- payroll_line_insert.sql — one prorated payroll line. Last param is the audit_id.
-- $1 = run_id, $2 = engineer_id, $3 = amount, $4 = days.
INSERT INTO payroll_line (run_id, engineer_id, amount, days, audit_id)
VALUES ($1, $2, $3, $4, $5);
