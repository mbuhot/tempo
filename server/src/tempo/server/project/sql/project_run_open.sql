-- project_run_open.sql — open a project's run (existence/contract window), contained
-- by its contract via project_within_contract. Last param is the audit_id.
-- $1 = project_id, $2 = contract_id, $3 = from, $4 = to.
INSERT INTO project_run (project_id, contract_id, active_during, audit_id)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'), $5);
