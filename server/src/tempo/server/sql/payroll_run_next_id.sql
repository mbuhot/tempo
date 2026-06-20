-- payroll_run_next_id.sql — reserve the next payroll run id from its sequence.
--
-- Called before run_payroll records any payroll fact: the handler threads this id
-- into the PayrollRun anchor, its period, and lines in one transaction, so nothing is
-- read back.
SELECT nextval('payroll_run_id_seq')::int AS id;
