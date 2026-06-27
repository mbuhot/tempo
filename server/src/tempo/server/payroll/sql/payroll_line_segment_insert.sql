-- payroll_line_segment_insert.sql — one frozen per-level payroll segment (#23). Last
-- param is the audit_id. $1 = run_id, $2 = engineer_id, $3 = level, $4 = monthly
-- salary (exact decimal text), $5 = days, $6 = amount (exact decimal text).
INSERT INTO payroll_line_segment
  (run_id, engineer_id, level, monthly_salary, days, amount, audit_id)
VALUES ($1, $2, $3, $4::text::numeric, $5, $6::text::numeric, $7);
