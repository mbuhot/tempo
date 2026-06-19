-- payroll_run_create.sql — mint a new payroll run identity (ID-ONLY anchor).
--
-- Step 1 of run_payroll (anchor → period → lines). `payroll_run.id` is GENERATED
-- ALWAYS AS IDENTITY, so the caller supplies nothing; RETURNING hands back the
-- minted id to thread into the payroll_period and line inserts. The run's period is
-- written separately into the 1:1 immutable payroll_period fact by
-- payroll_period_insert.
INSERT INTO payroll_run DEFAULT VALUES
RETURNING id;
