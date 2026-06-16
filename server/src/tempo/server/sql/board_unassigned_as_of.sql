-- board_unassigned_as_of.sql — employed engineers who are NOT allocated and NOT
-- on leave as of $1::date (ARCHITECTURE.md §5). The third board slice alongside
-- board_as_of (engaged) and board_leave_as_of (on leave); the client renders
-- these as "Unassigned".
--
-- INNER JOIN engineer_role so `level` is non-null: an employed engineer always
-- has a role in the seed (engineer_role spans employment). All columns non-null,
-- so the row decodes without Option plumbing.
SELECT
  engineer.name AS engineer,
  engineer_role.level
FROM employment
JOIN engineer       ON engineer.id = employment.engineer_id
JOIN engineer_role  ON engineer_role.engineer_id = engineer.id AND engineer_role.valid_at @> $1::date
WHERE employment.valid_at @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM allocation
    WHERE allocation.engineer_id = engineer.id AND allocation.valid_at @> $1::date
  )
  AND NOT EXISTS (
    SELECT 1 FROM leave
    WHERE leave.engineer_id = engineer.id AND leave.valid_at @> $1::date
  )
ORDER BY engineer.name;
