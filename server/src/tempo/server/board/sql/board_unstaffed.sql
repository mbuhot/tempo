-- board_unstaffed.sql — active projects with ZERO allocations on the date
-- ($1::date). The project-keyed companion to board_unassigned (which is keyed
-- on the engineer); the client renders these as the board's "Unstaffed" lane.
--
-- A project is active when its run covers $1 (project_run.active_during @> $1).
-- It is unstaffed when NO allocation covers $1 (NOT EXISTS). Counting allocations
-- (not engagements) means a project staffed only by an on-leave engineer is NOT
-- unstaffed — the allocation still covers the date — consistent with team_size.
-- Title comes from project_current; the owning client name through the run's
-- contract to client_current. All columns non-null, so the row decodes plainly.
SELECT
  project_run.project_id,
  coalesce(project_current.title, '') AS title,
  coalesce(client_current.name, '') AS client
FROM project_run
JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id AND contract_terms.term @> $1::date
JOIN client_current ON client_current.id = contract_terms.client_id
JOIN project_current ON project_current.id = project_run.project_id
WHERE project_run.active_during @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM allocation
    WHERE allocation.project_id = project_run.project_id
      AND allocation.allocated_during @> $1::date
  )
ORDER BY title;
