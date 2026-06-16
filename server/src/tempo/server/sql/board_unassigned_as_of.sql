-- board_unassigned_as_of.sql — employed engineers who are NOT allocated and NOT
-- on leave as of $1::date (ARCHITECTURE.md §5). The third board slice alongside
-- board_as_of (engaged) and board_leave_as_of (on leave); the client renders
-- these as "Unassigned".
--
-- INNER JOIN engineer_role so `level` is non-null: an employed engineer always
-- has a role in the seed (engineer_role spans employment). All columns non-null,
-- so the row decodes without Option plumbing.
SELECT
  e.name AS engineer,
  rl.level
FROM employment emp
JOIN engineer e       ON e.id = emp.engineer_id
JOIN engineer_role rl ON rl.engineer_id = e.id AND rl.valid_at @> $1::date
WHERE emp.valid_at @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM allocation al
    WHERE al.engineer_id = e.id AND al.valid_at @> $1::date
  )
  AND NOT EXISTS (
    SELECT 1 FROM leave lv
    WHERE lv.engineer_id = e.id AND lv.valid_at @> $1::date
  )
ORDER BY e.name;
