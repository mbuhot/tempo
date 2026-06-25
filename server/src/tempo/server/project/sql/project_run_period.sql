-- project_run_period.sql — one project's run window and owning client for the
-- detail read model (GET /api/projects/:id). Params: $1 = project_id, $2 = as-of
-- (for the active flag only).
--
-- The run is the project's existence/contract window (project_run). Its bounds are
-- decomposed to plain dates: lower(active_during) AS valid_from,
-- upper(active_during) AS valid_to (non-null for every seed run — all bounded at
-- 2027-01-01). `active` is (active_during @> $2): the as-of marks the run
-- active/ended without hiding it. The client name is reached through the run's
-- contract (contract_terms) to the client_current latest-read view; the contract is
-- joined on the same as-of so the name read matches the run window. A project may
-- have multiple historical runs — DISTINCT ON keeps the one whose window covers $2
-- (ordered so a covering run sorts first), falling back to the latest-started run
-- when none covers $2 so the detail page still renders an ended project. No row =>
-- the detail endpoint 404s.
SELECT DISTINCT ON (project_run.project_id)
  lower(project_run.active_during) AS valid_from,
  upper(project_run.active_during) AS valid_to,
  (project_run.active_during @> $2::date) AS active,
  coalesce(client_current.name, '') AS client
FROM project_run
JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
JOIN client_current ON client_current.id = contract_terms.client_id
WHERE project_run.project_id = $1
ORDER BY project_run.project_id,
         (project_run.active_during @> $2::date) DESC,
         lower(project_run.active_during) DESC;
