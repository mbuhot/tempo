-- board_engaged.sql — engineers ALLOCATED to a project on the date ($1::date).
-- One row per (engineer × project).
--
-- This is the "engaged" slice of the board; it returns only fully-engaged rows
-- (INNER JOINs throughout), so every column is non-null. Two companion queries
-- complete the board so every employed engineer is represented exactly once per
-- engagement:
--   * board_unassigned.sql — employed, not on leave, with no allocation
--   * board_leave.sql       — covered by a leave fact (leave overrides)
-- Engineers with a covering leave fact are suppressed here (NOT EXISTS) and
-- surfaced by board_leave.sql instead.
--
-- Charge rate is resolved from engineer_role × rate_card on the date (the
-- two-hop temporal join). It is exposed as a plain `day_rate` value on the row.
--
-- Range columns are decomposed to plain `date`s at the boundary: the engagement
-- window is `lower(allocation.allocated_during)`/`upper(allocation.allocated_during)` AS
-- valid_from/valid_to.
SELECT
  coalesce(engineer.name, '') AS engineer,
  engineer_role.level,
  coalesce(project.title, '') AS project,
  coalesce(client.name, '') AS client,
  allocation.fraction,
  rate_card.day_rate,
  lower(allocation.allocated_during) AS valid_from,
  upper(allocation.allocated_during) AS valid_to
FROM employment
JOIN engineer_current engineer ON engineer.id = employment.engineer_id
JOIN engineer_role  ON engineer_role.engineer_id = engineer.id  AND engineer_role.held_during @> $1::date
JOIN rate_card      ON rate_card.level = engineer_role.level    AND rate_card.effective_during @> $1::date
JOIN allocation     ON allocation.engineer_id = engineer.id     AND allocation.allocated_during @> $1::date
JOIN project_run    ON project_run.project_id = allocation.project_id  AND project_run.active_during @> $1::date
JOIN project_current project ON project.id = project_run.project_id
JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id  AND contract_terms.term @> $1::date
JOIN client_current client ON client.id = contract_terms.client_id
WHERE employment.employed_during @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM leave
    WHERE leave.engineer_id = engineer.id AND leave.on_leave_during @> $1::date
  )
ORDER BY engineer.name, project.title;
