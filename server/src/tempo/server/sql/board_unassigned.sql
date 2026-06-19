-- board_unassigned.sql — employed engineers who are NOT allocated and NOT
-- on leave on the date ($1::date). The third board slice alongside
-- board_engaged (engaged) and board_leave (on leave); the client renders
-- these as "Unassigned".
--
-- INNER JOIN engineer_role so `level` is non-null: an employed engineer always
-- has a role in the seed (engineer_role spans employment). All columns non-null,
-- so the row decodes without Option plumbing.
SELECT
  coalesce(engineer.name, '') AS engineer,
  engineer_role.level
FROM employment
JOIN engineer_current engineer ON engineer.id = employment.engineer_id
JOIN engineer_role  ON engineer_role.engineer_id = engineer.id AND engineer_role.held_during @> $1::date
WHERE employment.employed_during @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM allocation
    WHERE allocation.engineer_id = engineer.id AND allocation.allocated_during @> $1::date
  )
  AND NOT EXISTS (
    SELECT 1 FROM leave
    WHERE leave.engineer_id = engineer.id AND leave.on_leave_during @> $1::date
  )
ORDER BY engineer.name;
