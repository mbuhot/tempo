-- project_list.sql — the projects-directory read model (GET /api/projects?as_of=$1;
-- FR-CP5). One row per project that has a run: title, owning client, budget, target,
-- the team size on $1, and whether the run covers $1 (active). Param: $1 = as-of.
--
-- project_run anchors the project (every listed project has a run). A project may
-- have several historical runs, so DISTINCT ON (project_id) keeps the run covering
-- $1 (sorted first), falling back to the latest-started run for an ended project so
-- it still lists with active=false — a started project is marked active/ended, never
-- hidden. A run that has NOT started by $1 is excluded (lower(active_during) <= $1),
-- so a project dormant before its start is absent, not rendered as 'ended'.
-- The title comes from project_current, the client name through the run's contract
-- to client_current, and budget/target from a LATERAL latest-read project_plan
-- (DISTINCT ON by start desc, like project_plan_current; coalesced for a planless
-- project). team_size is a correlated count of DISTINCT engineers whose allocation
-- to this project covers $1 (0 for a dormant project). The inner DISTINCT ON picks
-- one run per project; the outer query orders the directory by title.
SELECT project_id, title, client, budget, target_completion, team_size, active
FROM (
  SELECT DISTINCT ON (project_run.project_id)
    project_run.project_id,
    coalesce(project_current.title, '') AS title,
    coalesce(client_current.name, '') AS client,
    coalesce(plan.budget, 0)::numeric AS budget,
    coalesce(plan.target_completion, upper(project_run.active_during)) AS target_completion,
    (
      SELECT count(DISTINCT allocation.engineer_id)
        FROM allocation
       WHERE allocation.project_id = project_run.project_id
         AND allocation.allocated_during @> $1::date
    )::int AS team_size,
    (project_run.active_during @> $1::date) AS active
  FROM project_run
  JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
  JOIN client_current ON client_current.id = contract_terms.client_id
  JOIN project_current ON project_current.id = project_run.project_id
  LEFT JOIN LATERAL (
    SELECT project_plan.budget, project_plan.target_completion
      FROM project_plan
     WHERE project_plan.project_id = project_run.project_id
     ORDER BY lower(project_plan.planned_during) DESC
     LIMIT 1
  ) plan ON true
  WHERE lower(project_run.active_during) <= $1::date
  ORDER BY project_run.project_id,
           (project_run.active_during @> $1::date) DESC,
           lower(project_run.active_during) DESC
) ranked
ORDER BY title;
