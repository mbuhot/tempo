-- engineer_allocations.sql — one engineer's full allocation timeline for the detail
-- read model (GET /api/engineers/:id; the AllocationRow list). Params:
-- $1 = engineer_id, $2 = as-of (for the active flag only).
--
-- Joined to project_current for the title and the project anchor for the clickable
-- id. Range decomposed to dates: lower(allocated_during) AS valid_from. An open
-- allocation has a NULL upper — `ongoing` reports it and `valid_to` coalesces to the
-- start (a non-null date the boundary decodes; the server maps ongoing -> None).
-- `active` is (allocated_during @> $2). Ordered oldest-first then by title.
SELECT
  allocation.project_id,
  coalesce(project_current.title, '') AS project,
  allocation.fraction,
  lower(allocation.allocated_during) AS valid_from,
  coalesce(upper(allocation.allocated_during), lower(allocation.allocated_during))
    AS valid_to,
  (allocation.allocated_during @> $2::date) AS active,
  upper_inf(allocation.allocated_during) AS ongoing
FROM allocation
JOIN project_current ON project_current.id = allocation.project_id
WHERE allocation.engineer_id = $1
ORDER BY lower(allocation.allocated_during), project;
