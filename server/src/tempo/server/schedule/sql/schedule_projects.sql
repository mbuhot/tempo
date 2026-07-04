-- schedule_projects.sql — projects whose run overlaps the 12-week window opening
-- at the Monday of $1. Runs are bounded (contained in bounded contract terms),
-- so upper() is safe. $1 = as_of.
SELECT
  project_run.project_id,
  coalesce(project_current.title, '') AS title,
  coalesce(client_current.name, '') AS client,
  lower(project_run.active_during) AS run_from,
  upper(project_run.active_during) AS run_to
FROM project_run
JOIN contract_terms
  ON contract_terms.contract_id = project_run.contract_id
 AND contract_terms.term @> lower(project_run.active_during)
JOIN client_current ON client_current.id = contract_terms.client_id
JOIN project_current ON project_current.id = project_run.project_id
WHERE project_run.active_during
   && daterange(date_trunc('week', $1::date)::date,
                (date_trunc('week', $1::date) + interval '12 weeks')::date, '[)')
ORDER BY title;
