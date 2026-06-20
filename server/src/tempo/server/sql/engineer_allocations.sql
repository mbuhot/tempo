-- engineer_allocations.sql — one engineer's full allocation timeline for the detail
-- read model (GET /api/engineers/:id; the AllocationRow list). Params:
-- $1 = engineer_id, $2 = as-of (for the active flag only).
--
-- Every allocation period-row for the engineer joined to project_current for the
-- title (and to the project anchor for the clickable project_id). Range columns are
-- decomposed to plain dates: lower(allocated_during) AS valid_from,
-- upper(allocated_during) AS valid_to (non-null for every seed row). `active` is
-- (allocated_during @> $2) — the as-of marks each row active/ended per FR-PE4
-- without hiding it, so the whole history is returned regardless of $2. Ordered
-- oldest-first then by title for a stable list.
SELECT
  allocation.project_id,
  coalesce(project_current.title, '') AS project,
  allocation.fraction,
  lower(allocation.allocated_during) AS valid_from,
  upper(allocation.allocated_during) AS valid_to,
  (allocation.allocated_during @> $2::date) AS active
FROM allocation
JOIN project_current ON project_current.id = allocation.project_id
WHERE allocation.engineer_id = $1
ORDER BY lower(allocation.allocated_during), project;
