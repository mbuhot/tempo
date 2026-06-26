-- client_projects.sql — one client's projects for the detail read model (GET
-- /api/clients/:id; the ClientProjectRow list; FR-CP1). Params: $1 = client_id,
-- $2 = as-of (for the active flag only).
--
-- A multi-hop temporal join from the client's contracts out to its projects:
-- contract_terms (the client's contracts) → project_run (each contract's project
-- runs) → project_current for the title and a LATERAL latest-read project_plan for
-- the budget/target. The run window is decomposed to plain dates: lower/upper
-- active_during AS valid_from/valid_to (non-null for every seed run, bounded at
-- 2027-01-01). `active` is (active_during @> $2) — the as-of marks each project
-- active/ended without hiding it, so the whole list is returned regardless of $2.
-- The plan is the most-recently-effective project_plan row (DISTINCT ON by start
-- desc, like project_plan_current) so budget/target are scalar; a project with no
-- plan yet coalesces budget to 0 and falls back to the run end for target. Ordered
-- by run start then title.
SELECT
  project_run.project_id,
  coalesce(project_current.title, '') AS title,
  coalesce(plan.budget, 0)::text AS budget,
  coalesce(plan.target_completion, upper(project_run.active_during)) AS target_completion,
  lower(project_run.active_during) AS valid_from,
  upper(project_run.active_during) AS valid_to,
  (project_run.active_during @> $2::date) AS active
FROM contract_terms
JOIN project_run ON project_run.contract_id = contract_terms.contract_id
JOIN project_current ON project_current.id = project_run.project_id
LEFT JOIN LATERAL (
  SELECT project_plan.budget, project_plan.target_completion
    FROM project_plan
   WHERE project_plan.project_id = project_run.project_id
   ORDER BY lower(project_plan.planned_during) DESC
   LIMIT 1
) plan ON true
WHERE contract_terms.client_id = $1
ORDER BY lower(project_run.active_during), title;
