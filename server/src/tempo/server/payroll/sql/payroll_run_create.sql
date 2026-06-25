-- payroll_run_create.sql — insert the payroll run identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of run_payroll. The id is reserved up-front from payroll_run_id_seq
-- (payroll_run_next_id) and supplied as $1, so this is a plain insert with no
-- RETURNING. The period/lines are separate facts recorded alongside.
INSERT INTO payroll_run (id) VALUES ($1);
