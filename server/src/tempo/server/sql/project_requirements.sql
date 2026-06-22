-- project_requirements.sql — one project's capacity-requirement lines (demand) for
-- the project-detail read model (GET /api/projects/:id; FR-CP). Param: $1 =
-- project_id.
--
-- Every requirement period-row for the project. Range columns are decomposed to
-- plain dates: lower(required_during) AS valid_from, upper(required_during) AS
-- valid_to (non-null for every row). One line per (project, level) over
-- non-overlapping periods. The detail is as-of-independent — the whole demand
-- timeline is returned regardless of the slider date — so unlike team/invoices this
-- read takes no as-of. Ordered by level then valid_from for a stable list.
SELECT
  project_requirement.project_id,
  project_requirement.level,
  project_requirement.quantity,
  lower(project_requirement.required_during) AS valid_from,
  upper(project_requirement.required_during) AS valid_to
FROM project_requirement
WHERE project_requirement.project_id = $1
ORDER BY project_requirement.level, lower(project_requirement.required_during);
