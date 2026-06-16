-- board_as_of.sql — the as-of org board: engineers ALLOCATED to a project as of
-- $1::date. One row per (engineer × project).
--
-- This is the "engaged" slice of the board; it returns only fully-engaged rows
-- (INNER JOINs throughout), so every column is non-null. Two companion queries
-- complete the board so every employed engineer is represented exactly once per
-- engagement:
--   * board_unassigned_as_of.sql — employed, not on leave, with no allocation
--   * board_leave_as_of.sql       — covered by a leave fact (leave overrides)
-- Engineers with a covering leave fact are suppressed here (NOT EXISTS) and
-- surfaced by board_leave_as_of.sql instead.
--
-- Charge rate is resolved from engineer_role × rate_card as of the date (the
-- two-hop temporal join). It is exposed as a plain `day_rate` value on the row.
--
-- Range columns are decomposed to plain `date`s at the boundary: the engagement
-- window is `lower(allocation.valid_at)`/`upper(allocation.valid_at)` AS
-- valid_from/valid_to.
SELECT
  engineer.name AS engineer,
  engineer_role.level,
  project.name AS project,
  client.name AS client,
  allocation.fraction,
  rate_card.day_rate,
  lower(allocation.valid_at) AS valid_from,
  upper(allocation.valid_at) AS valid_to
FROM employment
JOIN engineer       ON engineer.id = employment.engineer_id
JOIN engineer_role  ON engineer_role.engineer_id = engineer.id  AND engineer_role.valid_at @> $1::date
JOIN rate_card      ON rate_card.level = engineer_role.level    AND rate_card.valid_at @> $1::date
JOIN allocation     ON allocation.engineer_id = engineer.id     AND allocation.valid_at @> $1::date
JOIN project        ON project.id = allocation.project_id       AND project.valid_at @> $1::date
JOIN contract       ON contract.id = project.contract_id        AND contract.valid_at @> $1::date
JOIN client         ON client.id = contract.client_id
WHERE employment.valid_at @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM leave
    WHERE leave.engineer_id = engineer.id AND leave.valid_at @> $1::date
  )
ORDER BY engineer.name, project.name;
