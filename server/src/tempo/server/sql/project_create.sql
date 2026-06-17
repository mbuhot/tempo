-- project_create.sql — assert a new project under a contract (start_project).
--
-- A plain INSERT (write pattern 1). The project id is NOT generated: it is an
-- entity id reused across period-rows, so we mint a fresh one with
-- coalesce(max(id),0)+1. The project runs under an existing contract_id ($1)
-- and is contained by it via the project_within_contract PERIOD FK.
-- active_during = daterange($3, $4, '[)'); $4 may be NULL for an open run.
INSERT INTO project (id, contract_id, name, active_during)
VALUES (
  (SELECT coalesce(max(id), 0) + 1 FROM project),
  $1,
  $2,
  daterange($3::date, $4::date, '[)')
)
RETURNING id;
