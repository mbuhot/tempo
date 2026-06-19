-- payroll_period_insert.sql — record a payroll run's immutable period (1:1 fact).
--
-- A plain INSERT (write pattern 1) into the 1:1 payroll_period fact, keyed by the
-- minted payroll_run anchor id. The period is set once at run and never changed:
-- $1 = run_id, $2/$3 = the half-open [from, to) month bounds, built into a daterange
-- in SQL. The payroll_period_no_overlap GiST exclusion forbids two runs whose
-- periods overlap.
INSERT INTO payroll_period (run_id, period)
VALUES ($1, daterange($2::date, $3::date, '[)'));
