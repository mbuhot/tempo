-- project_run_open.sql — open a project's run (existence/contract window).
--
-- Step 2 of start_project: insert the project_run row over [$3, $4) under contract
-- $2, contained by the contract's term via the project_within_contract PERIOD FK —
-- a run whose active period falls outside the contract's term is rejected by the
-- database. active_during = daterange($3, $4, '[)'); $4 may be NULL for an open run.
-- $1 = project_id, $2 = contract_id, $3 = valid_from, $4 = valid_to.
INSERT INTO project_run (project_id, contract_id, active_during)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'));
